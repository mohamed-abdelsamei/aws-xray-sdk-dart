import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

// ignore: implementation_imports — test needs direct access to encode()
import 'package:aws_xray_sdk/src/sender/segment_encoder.dart' as enc;

void main() {
  group('segment_encoder', () {
    Segment makeSegment() => Segment.begin(
          name: 'svc',
          traceId: TraceId.generate(),
        ).close();

    test('encode small segment returns one payload', () {
      final payloads = enc.encode(makeSegment());
      expect(payloads, hasLength(1));
    });

    test('payload starts with X-Ray header', () {
      final payload = enc.encode(makeSegment()).first;
      final text = utf8.decode(payload);
      expect(text, startsWith('{"format":"json","version":1}\n'));
    });

    test('payload is valid JSON after header', () {
      final payload = enc.encode(makeSegment()).first;
      final text = utf8.decode(payload);
      final body = text.substring(text.indexOf('\n') + 1);
      expect(() => jsonDecode(body), returnsNormally);
    });

    test('oversized segment splits into multiple payloads', () {
      // Build a segment with many subsegments to push it over the 65507-byte cap.
      var segment = Segment.begin(name: 'svc', traceId: TraceId.generate());
      for (var i = 0; i < 200; i++) {
        final sub = Subsegment.begin(name: 'op-$i', namespace: 'aws')
            .annotate('data', 'x' * 500)
            .close();
        segment = segment.addSubsegment(sub);
      }
      segment = segment.close();

      final payloads = enc.encode(segment);
      expect(payloads.length, greaterThan(1));
      for (final p in payloads) {
        expect(p.length, lessThanOrEqualTo(65507));
      }
    });

    Map<String, Object?> bodyOf(List<int> payload) {
      final text = utf8.decode(payload);
      return jsonDecode(text.substring(text.indexOf('\n') + 1))
          as Map<String, Object?>;
    }

    test('split emits a skeleton segment plus independent subsegment docs', () {
      var segment = Segment.begin(name: 'svc', traceId: TraceId.generate());
      for (var i = 0; i < 200; i++) {
        segment = segment.addSubsegment(
          Subsegment.begin(name: 'op-$i', namespace: 'aws')
              .annotate('data', 'x' * 500)
              .close(),
        );
      }
      segment = segment.close();

      final payloads = enc.encode(segment);
      final skeleton = bodyOf(payloads.first);
      expect(skeleton['id'], segment.id);
      expect(skeleton.containsKey('subsegments'), isFalse,
          reason: 'skeleton must not inline subsegments');

      for (final p in payloads.skip(1)) {
        final doc = bodyOf(p);
        expect(doc['type'], 'subsegment');
        expect(doc['parent_id'], segment.id);
        expect(doc['trace_id'], segment.traceId.toString());
      }
    });

    test('recursively splits a subsegment whose children overflow the cap', () {
      // One top-level subsegment with many large children: inlined, its own
      // document exceeds the 65507-byte cap, so it must be split into the node + each child
      // re-parented to it.
      var big = Subsegment.begin(name: 'parent', namespace: 'aws');
      for (var i = 0; i < 200; i++) {
        big = big.addChild(
          Subsegment.begin(name: 'child-$i', namespace: 'aws')
              .annotate('data', 'x' * 500)
              .close(),
        );
      }
      final parentId = big.id;
      var segment = Segment.begin(name: 'svc', traceId: TraceId.generate())
          .addSubsegment(big.close())
          .close();

      final payloads = enc.encode(segment);
      for (final p in payloads) {
        expect(p.length, lessThanOrEqualTo(65507));
      }

      // The children must be parented to the big subsegment, not the segment.
      final childDocs = payloads
          .map(bodyOf)
          .where((d) => (d['name'] as String?)?.startsWith('child-') ?? false)
          .toList();
      expect(childDocs, hasLength(200));
      for (final d in childDocs) {
        expect(d['parent_id'], parentId);
        expect(d['type'], 'subsegment');
      }
    });
  });

  group('encode datagram cap', () {
    const cap = 65507;

    // A closed segment with one child, padded via an annotation so its
    // single-document encoding is exactly [size] bytes.
    Segment sized(int size) {
      final seg = Segment.begin(name: 'svc', traceId: TraceId.generate())
          .addSubsegment(Subsegment.begin(name: 'child').close())
          .close();
      final base = enc.encode(seg.annotate('pad', ''))[0].length;
      return seg.annotate('pad', 'x' * (size - base));
    }

    test('a document of exactly 65507 bytes is one packet', () {
      final out = enc.encode(sized(cap));
      expect(out, hasLength(1));
      expect(out[0], hasLength(cap));
    });

    for (final size in [cap + 1, 64 * 1024]) {
      test('a $size-byte document is split, every packet <= $cap', () {
        final out = enc.encode(sized(size));
        expect(out, hasLength(2));
        for (final p in out) {
          expect(p.length, lessThanOrEqualTo(cap));
        }
      });
    }
  });

  group('encodeSubsegmentDocs', () {
    const cap = 65507;
    const parentId = 'abcdef1234567890';
    final traceId = TraceId.generate().toString();

    Map<String, Object?> decode(List<int> payload) {
      final text = utf8.decode(payload);
      return jsonDecode(text.substring(text.indexOf('\n') + 1))
          as Map<String, Object?>;
    }

    // A root with one child, plus a json override (namespace removed, as
    // runLambda does) padded so the whole document is exactly [size] bytes.
    // Padding the override map — not the Subsegment — keeps the size exact.
    (Subsegment, Map<String, Object?>) sized(int size) {
      final child =
          Subsegment.begin(name: 'child', namespace: 'remote').close();
      final sub = Subsegment.begin(name: 'root').addChild(child).close();
      Map<String, Object?> padded(int n) => (sub.toJson()..remove('namespace'))
        ..['metadata'] = {
          'default': {'pad': 'x' * n},
        };
      final base = enc.encodeSubsegmentDoc(padded(0), parentId, traceId).length;
      return (sub, padded(size - base));
    }

    for (final (label, size) in [
      ('one byte under the cap', cap - 1),
      ('exactly at the cap', cap),
    ]) {
      test('$label stays one byte-identical packet', () {
        final (sub, json) = sized(size);
        final whole = enc.encodeSubsegmentDoc(json, parentId, traceId);
        expect(whole, hasLength(size));

        final out =
            enc.encodeSubsegmentDocs(sub, parentId, traceId, json: json);
        expect(out, [whole]);
      });
    }

    test('one byte over the cap splits root and child', () {
      final (sub, json) = sized(cap + 1);
      expect(
          enc.encodeSubsegmentDoc(json, parentId, traceId), hasLength(cap + 1));

      final out = enc.encodeSubsegmentDocs(sub, parentId, traceId, json: json);
      expect(out, hasLength(2));
      final root = decode(out[0]);
      final child = decode(out[1]);
      expect(root.containsKey('subsegments'), isFalse);
      expect(root.containsKey('namespace'), isFalse);
      expect(root['parent_id'], parentId);
      expect(child['parent_id'], sub.id);
      expect(child['namespace'], 'remote');
    });

    test('small doc is byte-identical to encodeSubsegmentDoc', () {
      final sub = Subsegment.begin(name: 'h')
          .addChild(Subsegment.begin(name: 'a', namespace: 'aws').close())
          .annotate('k', 1)
          .close();
      final json = sub.toJson()..remove('namespace');

      expect(
        enc.encodeSubsegmentDocs(sub, parentId, traceId, json: json),
        [enc.encodeSubsegmentDoc(json, parentId, traceId)],
      );
    });
  });
}
