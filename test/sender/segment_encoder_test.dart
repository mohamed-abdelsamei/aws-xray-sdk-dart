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
      // Build a segment with many subsegments to push it over 64 KB.
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
        expect(p.length, lessThanOrEqualTo(64 * 1024));
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
      // document exceeds 64 KB, so it must be split into the node + each child
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
        expect(p.length, lessThanOrEqualTo(64 * 1024));
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
}
