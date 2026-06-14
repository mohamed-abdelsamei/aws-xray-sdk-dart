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

  // Decode the last packet: strip the header line and parse the JSON body.
  Map<String, Object?> get lastDoc {
    final raw = utf8.decode(packets.last);
    final newline = raw.indexOf('\n');
    return jsonDecode(raw.substring(newline + 1)) as Map<String, Object?>;
  }
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
}
