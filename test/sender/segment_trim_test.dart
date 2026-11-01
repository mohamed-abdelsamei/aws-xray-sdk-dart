import 'dart:convert';
import 'dart:math';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
// ignore: implementation_imports — test needs direct access to the encoder
import 'package:aws_xray_sdk/src/sender/segment_encoder.dart' as enc;
import 'package:test/test.dart';

const _cap = 65507;

Map<String, Object?> _body(List<int> packet) {
  final text = utf8.decode(packet);
  return jsonDecode(text.substring(text.indexOf('\n') + 1))
      as Map<String, Object?>;
}

Map<String, Object?> _meta(Map<String, Object?> doc, String ns) =>
    ((doc['metadata'] as Map)[ns] as Map).cast<String, Object?>();

Subsegment _leaf(Map<String, Object> values, {String ns = 'default'}) {
  var sub = Subsegment.begin(name: 'leaf', namespace: 'aws')
      .annotate('keep', 'yes')
      .withFault();
  values.forEach((k, v) => sub = sub.addMetadata(k, v, namespace: ns));
  return sub.close();
}

Segment _rootWith(Segment Function(Segment) f,
    [List<Subsegment> subs = const []]) {
  var seg = f(Segment.begin(name: 'svc', traceId: TraceId.generate()));
  for (final s in subs) {
    seg = seg.addSubsegment(s);
  }
  return seg.close();
}

void main() {
  final traceId = TraceId.generate().toString();

  group('oversized node trimming', () {
    test('leaf: big value replaced, small kept, rest unchanged (docs path)',
        () {
      final leaf = _leaf({'big': 'x' * 70000, 'small': 'y' * 100});
      final packets =
          enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId);
      expect(packets, hasLength(1));
      expect(packets.single.length, lessThanOrEqualTo(_cap));
      final doc = _body(packets.single);
      final original = leaf.toJson();
      expect(_meta(doc, 'default')['big'], '[truncated: 70002 bytes]');
      expect(_meta(doc, 'default')['small'], 'y' * 100);
      expect(_meta(doc, 'xray'), {'truncated': true});
      for (final k in [
        'id',
        'name',
        'start_time',
        'end_time',
        'fault',
        'annotations',
        'namespace',
      ]) {
        expect(doc[k], jsonDecode(jsonEncode(original[k])), reason: k);
      }
    });

    test('leaf inside an oversized segment through encode()', () {
      final seg = _rootWith(
        (s) => s,
        [
          _leaf({'big': 'x' * 70000, 'small': 'y' * 100}),
          Subsegment.begin(name: 'other').close(),
        ],
      );
      final packets = enc.encode(seg);
      for (final p in packets) {
        expect(p.length, lessThanOrEqualTo(_cap));
      }
      final docs = packets.map(_body).toList();
      final leaf = docs.firstWhere((d) => d['name'] == 'leaf');
      expect(_meta(leaf, 'default')['small'], 'y' * 100);
      expect(_meta(leaf, 'xray')['truncated'], isTrue);
    });

    test('skeleton root over the cap keeps children as their own packets', () {
      final seg = _rootWith(
        (s) => s.addMetadata('big', 'x' * 70000).addMetadata('small', 'ok'),
        [
          Subsegment.begin(name: 'a').close(),
          Subsegment.begin(name: 'b').close(),
        ],
      );
      final packets = enc.encode(seg);
      expect(packets, hasLength(3));
      for (final p in packets) {
        expect(p.length, lessThanOrEqualTo(_cap));
      }
      final root = _body(packets.first);
      expect(_meta(root, 'default')['small'], 'ok');
      expect(_meta(root, 'default')['big'], startsWith('[truncated: '));
      expect(_meta(root, 'xray')['truncated'], isTrue);
      for (final p in packets.skip(1)) {
        final d = _body(p);
        expect(d['parent_id'], seg.id);
        expect(d['type'], 'subsegment');
        expect(d.containsKey('metadata'), isFalse);
      }
    });

    test('inner skeleton over the cap is trimmed and children re-parented', () {
      var inner =
          Subsegment.begin(name: 'inner').addMetadata('big', 'x' * 70000);
      final child = Subsegment.begin(name: 'child').close();
      inner = inner.addChild(child).close();
      final packets =
          enc.encodeSubsegmentDocs(inner, 'parent0000000001', traceId);
      expect(packets, hasLength(2));
      for (final p in packets) {
        expect(p.length, lessThanOrEqualTo(_cap));
      }
      expect(_meta(_body(packets[0]), 'xray')['truncated'], isTrue);
      expect(_body(packets[1])['parent_id'], inner.id);
    });

    test('exactly at the cap is untouched; one byte over is trimmed', () {
      // Find a filler length whose packet is exactly 65507 bytes.
      // One closed base node, so timestamps (and their digit counts) are fixed.
      final base0 = Subsegment.begin(name: 'leaf').close();
      List<int> docs(int n) => enc
          .encodeSubsegmentDocs(
            base0.addMetadata('v', 'x' * n),
            'parent0000000001',
            traceId,
          )
          .first;
      final base = docs(0).length;
      final exact = _cap - base;
      final atCap = docs(exact);
      expect(atCap.length, _cap);
      expect(utf8.decode(atCap), isNot(contains('xray')));
      expect(utf8.decode(atCap), contains('x' * exact));

      final over = docs(exact + 1);
      expect(over.length, lessThanOrEqualTo(_cap));
      expect(utf8.decode(over), contains('[truncated: '));
      expect(_meta(_body(over), 'xray')['truncated'], isTrue);
    });

    test('replaces the largest values, only as many as needed', () {
      final values = <String, Object>{
        for (var i = 0; i < 20; i++)
          'k${i.toString().padLeft(2, '0')}': ('${i % 10}' * (4000 + i * 10)),
      };
      final leaf = _leaf(values);
      final doc = _body(
        enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId).single,
      );
      final meta = _meta(doc, 'default');
      final replaced = [
        for (final e in meta.entries)
          if ((e.value as String).startsWith('[truncated: ')) e.key,
      ];
      expect(replaced, isNotEmpty);
      expect(replaced.length, lessThan(20));
      // Replaced ones are exactly the largest (highest index = longest).
      final expected = [
        for (var i = 20 - replaced.length; i < 20; i++)
          'k${i.toString().padLeft(2, '0')}',
      ];
      expect(replaced..sort(), expected);
      for (final e in meta.entries) {
        if (!replaced.contains(e.key)) expect(e.value, values[e.key]);
      }
      // One fewer replacement would not have fit.
      final fewer = <String, Object>{...values};
      for (final k in replaced.skip(1)) {
        fewer[k] = '[truncated: ${jsonEncode(values[k]).length} bytes]';
      }
      final s = utf8.encode(jsonEncode({
        ...leaf.toJson(),
        'metadata': {
          'default': fewer,
          'xray': {'truncated': true},
        },
        'type': 'subsegment',
        'parent_id': 'parent0000000001',
        'trace_id': traceId,
      }));
      expect(s.length + '{"format":"json","version":1}\n'.length,
          greaterThan(_cap));
    });

    test('a value shorter than its marker is left alone', () {
      // Many tiny values plus one huge one: tiny ones are never replaced.
      final leaf = _leaf({
        'huge': 'x' * 70000,
        'a': 1,
        'b': 'hi',
        'c': true,
      });
      final meta = _meta(
        _body(
            enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId).single),
        'default',
      );
      expect(meta['a'], 1);
      expect(meta['b'], 'hi');
      expect(meta['c'], true);
      expect(meta['huge'], startsWith('[truncated: '));
    });

    test('equal-size values: the earliest keys are replaced first', () {
      final values = <String, Object>{
        for (var i = 0; i < 20; i++)
          'k${i.toString().padLeft(2, '0')}': 'x' * 4096,
      };
      final leaf = _leaf(values);
      final packets =
          enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId);
      expect(packets.single.length, lessThanOrEqualTo(_cap));
      final meta = _meta(_body(packets.single), 'default');
      final replaced = [
        for (final e in meta.entries)
          if ((e.value as String).startsWith('[truncated: ')) e.key,
      ];
      expect(replaced, isNotEmpty);
      expect(replaced.length, lessThan(20));
      // Ties go to the earliest keys, so the replaced set is a prefix.
      expect(replaced, [
        for (var i = 0; i < replaced.length; i++)
          'k${i.toString().padLeft(2, '0')}',
      ]);
      expect(
        packets.single,
        enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId).single,
      );
    });

    test('a value shorter than its marker stays even when others go', () {
      // 'ab' encodes to 4 bytes, shorter than '[truncated: 4 bytes]'.
      final leaf = _leaf({'tiny': 'ab', 'big': 'x' * 70000});
      final meta = _meta(
        _body(
            enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId).single),
        'default',
      );
      expect(meta['tiny'], 'ab');
      expect(meta['big'], startsWith('[truncated: '));
      // A value just over the marker length is replaceable; one under is not.
      final mid = 'm' * 30;
      final leaf2 = _leaf({'mid': mid, 'big': 'x' * 70000});
      final meta2 = _meta(
        _body(enc
            .encodeSubsegmentDocs(leaf2, 'parent0000000001', traceId)
            .single),
        'default',
      );
      expect(meta2['mid'], mid, reason: 'only as many as needed');
    });

    test('existing xray namespace keeps its other keys', () {
      final leaf = _leaf({'big': 'x' * 70000});
      final withXray = leaf
          .addMetadata('incomplete', true, namespace: 'xray')
          .addMetadata('truncated', 'user', namespace: 'xray');
      final doc = _body(
        enc.encodeSubsegmentDocs(withXray, 'parent0000000001', traceId).single,
      );
      expect(_meta(doc, 'xray'), {'incomplete': true, 'truncated': true});
    });

    test('oversized annotation yields a bare node', () {
      final sub = Subsegment.begin(name: 'n', namespace: 'remote')
          .annotate('huge', 'z' * 70000)
          .addMetadata('m', 'small')
          .withError()
          .close();
      final packets =
          enc.encodeSubsegmentDocs(sub, 'parent0000000001', traceId);
      expect(packets, hasLength(1));
      expect(packets.single.length, lessThanOrEqualTo(_cap));
      final doc = _body(packets.single);
      expect(doc['id'], sub.id);
      expect(doc['parent_id'], 'parent0000000001');
      expect(doc['trace_id'], traceId);
      expect(doc['type'], 'subsegment');
      expect(doc['start_time'], sub.startTime);
      expect(doc['end_time'], sub.endTime);
      expect(doc['error'], true);
      expect(doc['namespace'], 'remote');
      expect(doc.containsKey('annotations'), isFalse);
      expect(doc['metadata'], {
        'xray': {'truncated': true},
      });
    });

    test('oversized name is capped at 200 code units', () {
      final sub = Subsegment.begin(name: 'n' * 200000).close();
      final doc = _body(
        enc.encodeSubsegmentDocs(sub, 'parent0000000001', traceId).single,
      );
      expect((doc['name'] as String).length, lessThanOrEqualTo(200));
      expect(_meta(doc, 'xray')['truncated'], isTrue);
    });

    test('name cap does not split a surrogate pair', () {
      final name = '${'a' * 199}\u{1F600}${'b' * 70000}';
      final sub = Subsegment.begin(name: name).close();
      final doc = _body(
        enc.encodeSubsegmentDocs(sub, 'parent0000000001', traceId).single,
      );
      expect(doc['name'], 'a' * 199);
    });

    test('oversized root skeleton annotation yields a bare root', () {
      final seg = _rootWith(
        (s) => s.annotate('huge', 'z' * 70000).withFault(),
        [Subsegment.begin(name: 'a').close()],
      );
      final packets = enc.encode(seg);
      expect(packets, hasLength(2));
      final root = _body(packets.first);
      expect(packets.first.length, lessThanOrEqualTo(_cap));
      expect(root['id'], seg.id);
      expect(root['trace_id'], seg.traceId.toString());
      expect(root['fault'], true);
      expect(root.containsKey('annotations'), isFalse);
      expect(_meta(root, 'xray')['truncated'], isTrue);
    });

    test('the model is not mutated and encoding is repeatable', () {
      final leaf = _leaf({'big': 'x' * 70000});
      final a = enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId);
      final b = enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId);
      expect(a.single, b.single);
      expect(leaf.metadata!['default']!['big'], 'x' * 70000);
      expect(leaf.metadata!.containsKey('xray'), isFalse);

      final seg = _rootWith((s) => s.addMetadata('big', 'x' * 70000),
          [Subsegment.begin(name: 'a').close()]);
      expect(enc.encode(seg).first, enc.encode(seg).first);
      expect(seg.metadata!['default']!['big'], 'x' * 70000);
    });

    test('a non-JSON-native value is measured as it is written', () {
      final when = DateTime.utc(2026, 1, 1);
      final list = List<Object>.filled(3000, when);
      final written = utf8.encode(
        jsonEncode(list, toEncodable: (o) => o.toString()),
      );
      expect(written.length, greaterThan(65507));
      final leaf = _leaf({'dates': list});
      final packets =
          enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId);
      expect(packets.single.length, lessThanOrEqualTo(_cap));
      expect(
        _meta(_body(packets.single), 'default')['dates'],
        '[truncated: ${written.length} bytes]',
      );
    });

    test('property: every packet fits for random nodes', () {
      final rnd = Random(20261101);
      for (var i = 0; i < 60; i++) {
        var sub = Subsegment.begin(
          name: rnd.nextInt(6) == 0 ? 'n' * (200 + rnd.nextInt(150000)) : 'n$i',
          namespace: rnd.nextBool() ? 'aws' : 'remote',
        );
        final nKeys = rnd.nextInt(30);
        for (var k = 0; k < nKeys; k++) {
          final size = rnd.nextInt(10) == 0 ? 300000 : rnd.nextInt(30000);
          sub = sub.addMetadata(
            'k$k',
            rnd.nextBool() ? 'é' * (size ~/ 2) : List.filled(size ~/ 8, 12345),
            namespace: 'ns${rnd.nextInt(3)}',
          );
        }
        if (rnd.nextInt(6) == 0) {
          sub = sub.annotate('a', 'z' * (50000 + rnd.nextInt(250000)));
        }
        final leaf = sub.close();

        final docs =
            enc.encodeSubsegmentDocs(leaf, 'parent0000000001', traceId);
        for (final p in docs) {
          expect(p.length, lessThanOrEqualTo(_cap), reason: 'iteration $i');
          expect(() => _body(p), returnsNormally);
        }

        final seg = _rootWith(
          (s) => s.addMetadata('big', 'x' * rnd.nextInt(300000)),
          [leaf],
        );
        for (final p in enc.encode(seg)) {
          expect(p.length, lessThanOrEqualTo(_cap), reason: 'segment $i');
        }
      }
    });

    test('deep chain and wide namespace map each fit in bounded packets', () {
      var node = Subsegment.begin(name: 'leaf')
          .addMetadata('big', 'x' * 80000)
          .close();
      for (var i = 0; i < 60; i++) {
        node = Subsegment.begin(name: 'level$i')
            .addMetadata('big', 'y' * 70000)
            .addChild(node)
            .close();
      }
      var wide = Subsegment.begin(name: 'wide');
      for (var i = 0; i < 2000; i++) {
        wide = wide.addMetadata('k', 'v' * 100, namespace: 'ns$i');
      }
      final chain = enc.encodeSubsegmentDocs(node, 'parent0000000001', traceId);
      // One packet per level plus the leaf, each within the cap.
      expect(chain, hasLength(61));
      for (final p in chain) {
        expect(p.length, lessThanOrEqualTo(_cap));
      }
      final wideDocs = enc.encodeSubsegmentDocs(
        wide.close(),
        'parent0000000001',
        traceId,
      );
      expect(wideDocs, hasLength(1));
      expect(wideDocs.single.length, lessThanOrEqualTo(_cap));
      expect(_meta(_body(wideDocs.single), 'xray')['truncated'], isTrue);
    });
  });
}
