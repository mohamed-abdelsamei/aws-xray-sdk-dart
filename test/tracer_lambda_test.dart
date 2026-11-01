import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

// Captures raw packets delivered via sendPackets (used by runLambda).
class _PacketSender extends Sender {
  final List<List<int>> packets = [];
  int sendSegmentCalls = 0;

  @override
  Future<void> send(Segment segment) async {
    sendSegmentCalls++;
  }

  @override
  Future<void> sendPackets(List<List<int>> ps) async => packets.addAll(ps);

  @override
  Future<void> close() async {}

  bool get isEmpty => packets.isEmpty;

  // Every packet decoded, in send order.
  List<Map<String, Object?>> get docs => [
        for (final p in packets)
          () {
            final raw = utf8.decode(p);
            return jsonDecode(raw.substring(raw.indexOf('\n') + 1))
                as Map<String, Object?>;
          }(),
      ];

  // Decode the last packet: strip the header line and parse the JSON body.
  Map<String, Object?> get lastDoc {
    final raw = utf8.decode(packets.last);
    final newline = raw.indexOf('\n');
    return jsonDecode(raw.substring(newline + 1)) as Map<String, Object?>;
  }
}

// A sender whose packet delivery always fails, to exercise onSendError.
class _ThrowingPacketSender extends Sender {
  @override
  Future<void> send(Segment segment) async {}
  @override
  Future<void> sendPackets(List<List<int>> ps) async =>
      throw StateError('daemon down');
  @override
  Future<void> close() async {}
}

// A custom sender that implements only send/close.
class _SendOnlySender extends Sender {
  @override
  Future<void> send(Segment segment) async {}
  @override
  Future<void> close() async {}
}

class _JsonThrowingSender extends Sender {
  @override
  Future<void> send(Segment segment) async {}
  @override
  Future<void> sendPackets(List<List<int>> ps) async {}
  @override
  Future<void> close() async {}
}

void main() {
  late _PacketSender sender;
  late XRayTracer tracer;

  setUp(() {
    sender = _PacketSender();
    tracer = XRayTracer(
      serviceName: 'lambda-svc',
      sender: sender,
      sampling: FixedRateSampler(1.0),
    );
  });

  final traceId = TraceId.generate();
  const parentId = 'abcdef1234567890';

  group('XRayTracer.runLambda — packet delivery', () {
    test('sends exactly one packet when sampled', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      expect(sender.packets, hasLength(1));
    });

    test('sends no packet when not sampled', () async {
      await tracer.runLambda(
        traceId,
        parentId,
        'handler',
        () async {},
        sampled: false,
      );
      expect(sender.isEmpty, isTrue);
    });

    test('unsampled invocation notifies drop before serialization', () async {
      Segment? dropped;
      final t = XRayTracer(
        serviceName: 'lambda-svc',
        sender: _JsonThrowingSender(),
        onSampledDrop: (s) => dropped = s,
      );

      await t.runLambda(
        traceId,
        parentId,
        'handler',
        () async {
          t.addMetadata('bad', Object());
        },
        sampled: false,
      );

      expect(dropped, isNotNull);
    });

    test('packet is sent even when fn throws', () async {
      await expectLater(
        () => tracer.runLambda(
          traceId,
          parentId,
          'handler',
          () async => throw Exception('boom'),
        ),
        throwsException,
      );
      expect(sender.packets, hasLength(1));
    });

    test('onSendError fires when the lambda packet send fails (M1)', () async {
      Object? captured;
      final t = XRayTracer(
        serviceName: 'lambda-svc',
        sender: _ThrowingPacketSender(),
        sampling: FixedRateSampler(1.0),
        onSendError: (s, e) => captured = e,
      );

      // The send failure must be surfaced but never escape the invocation.
      final result =
          await t.runLambda(traceId, parentId, 'handler', () async => 7);

      expect(result, 7);
      expect(captured, isA<StateError>());
    });
  });

  group('XRayTracer.runLambda — document shape', () {
    test('emitted doc has type=subsegment', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      expect(sender.lastDoc['type'], 'subsegment');
    });

    test('emitted doc links to the correct trace_id', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      expect(sender.lastDoc['trace_id'], traceId.toString());
    });

    test('emitted doc links to the correct parent_id', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      expect(sender.lastDoc['parent_id'], parentId);
    });

    test('emitted doc carries the handler name', () async {
      await tracer.runLambda(traceId, parentId, 'my-handler', () async {});
      expect(sender.lastDoc['name'], 'my-handler');
    });

    test('emitted doc has start_time and end_time', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      final doc = sender.lastDoc;
      expect(doc['start_time'], isA<double>());
      expect(doc['end_time'], isA<double>());
      expect((doc['end_time'] as double),
          greaterThanOrEqualTo(doc['start_time'] as double));
    });

    test('packet starts with the X-Ray header line', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      final raw = utf8.decode(sender.packets.last);
      expect(raw, startsWith('{"format":"json","version":1}\n'));
    });
  });

  group('XRayTracer.runLambda — zone context', () {
    test('currentSegment is non-null inside runLambda', () async {
      Segment? captured;
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        captured = tracer.currentSegment;
      });
      expect(captured, isNotNull);
    });

    test('currentSegment carries the correct traceId inside runLambda',
        () async {
      TraceId? capturedTraceId;
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        capturedTraceId = tracer.currentSegment?.traceId;
      });
      expect(capturedTraceId.toString(), traceId.toString());
    });

    test('isSampled reflects the sampled flag inside runLambda', () async {
      bool? sampledInside;
      await tracer.runLambda(
        traceId,
        parentId,
        'handler',
        () async {
          sampledInside = tracer.isSampled;
        },
        sampled: false,
      );
      expect(sampledInside, isFalse);
    });
  });

  group('XRayTracer.runLambda — subsegments', () {
    test('subsegments opened inside fn are embedded in the handler doc',
        () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        final sub = tracer.beginSubsegment('db-call');
        tracer.endSubsegment(sub);
      });

      final subs = sender.lastDoc['subsegments'] as List?;
      expect(subs, isNotNull);
      expect(subs, hasLength(1));
      expect((subs!.first as Map)['name'], 'db-call');
    });

    test('multiple subsegments all appear in the handler doc', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        for (final name in ['a', 'b', 'c']) {
          final sub = tracer.beginSubsegment(name);
          tracer.endSubsegment(sub);
        }
      });

      final subs = sender.lastDoc['subsegments'] as List?;
      expect(subs, hasLength(3));
      final names = subs!.map((s) => (s as Map)['name']).toList();
      expect(names, containsAll(['a', 'b', 'c']));
    });

    test('faulted subsegment is recorded inside the handler doc', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        final sub = tracer.beginSubsegment('bad-call');
        tracer.failSubsegment(sub, Exception('oops'));
      });

      final subs = sender.lastDoc['subsegments'] as List?;
      expect(subs, isNotNull);
      final sub = subs!.first as Map;
      expect(sub['fault'], isTrue);
    });

    test('handler doc has no subsegments key when fn does no tracing',
        () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      expect(sender.lastDoc.containsKey('subsegments'), isFalse);
    });

    test('captureAsync nests under the handler doc', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        await tracer.captureAsync('work', (span) async {
          final inner = tracer.beginSubsegment('db');
          tracer.endSubsegment(inner);
        });
      });

      final work = (sender.lastDoc['subsegments'] as List).first as Map;
      expect(work['name'], 'work');
      expect((work['subsegments'] as List).first['name'], 'db');
    });

    test('handler doc never carries a namespace field', () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      expect(sender.lastDoc.containsKey('namespace'), isFalse);
    });

    test('oversized handler doc is split into linked docs within 65507 bytes',
        () async {
      final big = 'x' * (20 * 1024);
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        for (var i = 0; i < 5; i++) {
          await tracer.captureAsync('child-$i', (span) async {
            tracer.addMetadata('blob', big);
          });
        }
      });

      expect(sender.packets.length, greaterThan(1));
      final docs = sender.packets.map((p) {
        expect(p.length, lessThanOrEqualTo(65507));
        final raw = utf8.decode(p);
        return jsonDecode(raw.substring(raw.indexOf('\n') + 1))
            as Map<String, Object?>;
      }).toList();

      final root = docs.first;
      expect(root['name'], 'handler');
      expect(root['parent_id'], parentId);
      expect(root.containsKey('namespace'), isFalse);
      expect(root.containsKey('subsegments'), isFalse);
      for (final d in docs) {
        expect(d['type'], 'subsegment');
        expect(d['trace_id'], traceId.toString());
      }
      final children = docs.skip(1).toList();
      expect(children.map((d) => d['name']),
          ['child-0', 'child-1', 'child-2', 'child-3', 'child-4']);
      for (final c in children) {
        expect(c['parent_id'], root['id']);
      }
    });

    test('oversized child is split recursively; children keep namespace',
        () async {
      final big = 'x' * (25 * 1024);
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        await tracer.captureAsync('outer', (_) async {
          for (var i = 0; i < 3; i++) {
            await tracer.captureAsync('g$i', (_) async {
              tracer.addMetadata('blob', big);
            }, namespace: 'aws');
          }
        }, namespace: 'remote');
        await tracer.captureAsync('small', (_) async {}, namespace: 'aws');
      });

      for (final p in sender.packets) {
        expect(p.length, lessThanOrEqualTo(65507));
      }
      final docs = sender.docs;
      expect(docs.map((d) => d['name']),
          ['handler', 'outer', 'g0', 'g1', 'g2', 'small']);

      final root = docs[0];
      final outer = docs[1];
      expect(root.containsKey('namespace'), isFalse);
      expect(root['parent_id'], parentId);
      expect(outer['parent_id'], root['id']);
      expect(outer['namespace'], 'remote');
      expect(outer.containsKey('subsegments'), isFalse);
      for (final g in docs.sublist(2, 5)) {
        expect(g['parent_id'], outer['id']);
        expect(g['namespace'], 'aws');
      }
      expect(docs[5]['parent_id'], root['id']);
      expect(docs[5]['namespace'], 'aws');
      for (final d in docs) {
        expect(d['trace_id'], traceId.toString());
        expect(d['type'], 'subsegment');
      }
      expect(docs.map((d) => d['id']).toSet(), hasLength(docs.length));
    });

    test('swept and faulted children keep their flags in split docs', () async {
      final big = 'x' * (40 * 1024);
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        final open =
            tracer.beginSubsegment('never-closed', namespace: 'remote');
        tracer.updatePending(open.addMetadata('blob', big));
        try {
          await tracer.captureAsync('boom', (_) async {
            tracer.addMetadata('blob', big);
            throw StateError('boom');
          });
        } on StateError catch (_) {}
      });

      final docs = sender.docs;
      expect(docs, hasLength(3));
      final rootId = docs[0]['id'];
      final byName = {for (final d in docs) d['name']: d};

      final swept = byName['never-closed']!;
      expect((swept['metadata'] as Map)['xray'], {'incomplete': true});
      expect(swept['namespace'], 'remote');
      expect(swept.containsKey('in_progress'), isFalse);
      expect(swept['parent_id'], rootId);

      final boom = byName['boom']!;
      expect(boom['fault'], isTrue);
      expect(boom['parent_id'], rootId);
    });
  });

  group('XRayTracer.runLambda — fault & annotations', () {
    test('handler doc is faulted when fn throws', () async {
      await expectLater(
        () => tracer.runLambda(
          traceId,
          parentId,
          'handler',
          () async => throw Exception('boom'),
        ),
        throwsException,
      );
      expect(sender.lastDoc['fault'], isTrue);
      expect(sender.lastDoc['cause'], isNotNull);
    });

    test('annotations set during the invocation land on the handler doc',
        () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {
        tracer.annotate('coldStart', true);
      });
      expect((sender.lastDoc['annotations'] as Map)['coldStart'], true);
    });
  });

  group('XRayTracer.runLambda — parent-segment contract', () {
    test('emits a subsegment document, never a competing root segment',
        () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      // The handler span goes out as an independent subsegment document via
      // sendPackets; the top-level segment path (send) is never used, so it
      // cannot compete with Lambda's auto-created AWS::Lambda::Function segment.
      expect(sender.lastDoc['type'], 'subsegment');
      expect(sender.sendSegmentCalls, 0);
    });

    test('handler doc parent_id links to the provided Lambda segment id',
        () async {
      await tracer.runLambda(traceId, parentId, 'handler', () async {});
      expect(sender.lastDoc['parent_id'], parentId);
    });

    test('does not emit even a subsegment document when not sampled', () async {
      await tracer.runLambda(
        traceId,
        parentId,
        'handler',
        () async {},
        sampled: false,
      );
      expect(sender.isEmpty, isTrue);
      expect(sender.sendSegmentCalls, 0);
    });

    test('an empty parent id (missing Parent= in the header) still emits a doc',
        () async {
      // When the Lambda trace header carries no Parent= field a caller may pass
      // an empty parent id. The handler span is still emitted (with an empty
      // parent_id) rather than being silently dropped.
      await tracer.runLambda(traceId, '', 'handler', () async {});
      expect(sender.packets, hasLength(1));
      expect(sender.lastDoc['type'], 'subsegment');
      expect(sender.lastDoc['parent_id'], '');
      expect(sender.lastDoc['trace_id'], traceId.toString());
    });

    test('a faulted handler with an empty parent id is still delivered',
        () async {
      await expectLater(
        () => tracer.runLambda(
          traceId,
          '',
          'handler',
          () async => throw Exception('boom'),
        ),
        throwsException,
      );
      expect(sender.packets, hasLength(1));
      expect(sender.lastDoc['fault'], isTrue);
    });
  });

  group('XRayTracer.runLambda — custom senders', () {
    test('a send-only custom Sender reports UnsupportedError via onSendError',
        () async {
      final errors = <Object>[];
      final t = XRayTracer(
        serviceName: 'lambda-svc',
        sender: _SendOnlySender(),
        sampling: FixedRateSampler(1.0),
        onSendError: (s, e) => errors.add(e),
      );

      final result =
          await t.runLambda(traceId, parentId, 'handler', () async => 7);

      expect(result, 7);
      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<UnsupportedError>()
            .having((e) => e.message, 'message', contains('_SendOnlySender'))
            .having((e) => e.message, 'message', contains('runLambda')),
      );
    });

    test('InMemorySender still captures the lambda packet', () async {
      final mem = InMemorySender();
      final errors = <Object>[];
      final t = XRayTracer(
        serviceName: 'lambda-svc',
        sender: mem,
        sampling: FixedRateSampler(1.0),
        onSendError: (s, e) => errors.add(e),
      );
      await t.runLambda(traceId, parentId, 'handler', () async {});
      expect(mem.packets, hasLength(1));
      expect(errors, isEmpty);
    });

    test('NoopSender stays a silent no-op', () async {
      final errors = <Object>[];
      final t = XRayTracer(
        serviceName: 'lambda-svc',
        sender: NoopSender(),
        sampling: FixedRateSampler(1.0),
        onSendError: (s, e) => errors.add(e),
      );
      expect(await t.runLambda(traceId, parentId, 'handler', () async => 1), 1);
      expect(errors, isEmpty);
      await expectLater(
          NoopSender().sendPackets([utf8.encode('x')]), completes);
    });
  });
}
