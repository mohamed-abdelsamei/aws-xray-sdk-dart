import 'dart:convert';
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

class _RecordingSender extends Sender {
  final List<Map<String, Object?>> sent = [];

  @override
  Future<void> send(Segment segment) async {
    sent.add(jsonDecode(jsonEncode(segment.toJson())) as Map<String, Object?>);
  }

  @override
  Future<void> close() async {}

  bool get isEmpty => sent.isEmpty;
  Map<String, Object?> get last => sent.last;
  List get lastSubs => last['subsegments'] as List? ?? const [];
}

/// Minimal [Stdout] that captures written text, for asserting on the
/// `ContextMissingPolicy.logError` diagnostic. Only the write methods used by
/// the tracer's `stderr.writeln` are meaningful; the rest are no-ops.
///
/// Implements [Stdout] (not just [IOSink]) because `IOOverrides.stderr` must
/// return a [Stdout].
class _CapturingSink implements Stdout {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  @override
  void writeln([Object? obj = '']) => _buffer.writeln(obj);

  @override
  void write(Object? obj) => _buffer.write(obj);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}

  // ---- Stdout-specific members (unused by the tracer) ----

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  int get terminalColumns => 80;

  @override
  int get terminalLines => 24;

  @override
  IOSink get nonBlocking => this;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _RecordingSender sender;
  late XRayTracer tracer;

  setUp(() {
    sender = _RecordingSender();
    tracer = XRayTracer(
      serviceName: 'test-svc',
      sender: sender,
      sampling: FixedRateSampler(1.0),
    );
  });

  group('XRayTracer — context', () {
    test('currentSegment is null outside a run()', () {
      expect(tracer.currentSegment, isNull);
    });

    test('currentSegment is side-effect free outside a run() zone', () {
      // Even with the strictest policy, the getter itself never throws — a
      // null result is the normal "no active trace" passthrough signal.
      final strictTracer = XRayTracer(
        serviceName: 'test-svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
        contextMissingPolicy: ContextMissingPolicy.runtimeError,
      );
      expect(strictTracer.currentSegment, isNull);
    });

    test('recording a subsegment ignores missing context by default', () {
      final defaultTracer = XRayTracer(
        serviceName: 'test-svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
      );
      final sub = defaultTracer.beginSubsegment('orphan');
      // No active run() zone: the data is dropped silently, no throw.
      expect(() => defaultTracer.endSubsegment(sub), returnsNormally);
    });

    test(
        'recording a subsegment throws when ContextMissingPolicy.runtimeError is set',
        () {
      final strictTracer = XRayTracer(
        serviceName: 'test-svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
        contextMissingPolicy: ContextMissingPolicy.runtimeError,
      );
      final sub = strictTracer.beginSubsegment('orphan');
      // No active run() zone: closing the subsegment surfaces the missing
      // context instead of silently dropping it.
      expect(() => strictTracer.endSubsegment(sub), throwsStateError);
    });

    test(
        'recording a subsegment writes a diagnostic when '
        'ContextMissingPolicy.logError is set', () {
      final logTracer = XRayTracer(
        serviceName: 'test-svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
        contextMissingPolicy: ContextMissingPolicy.logError,
      );

      final captured = _CapturingSink();
      IOOverrides.runZoned(
        () {
          final sub = logTracer.beginSubsegment('orphan');
          // No active run() zone: the data is dropped but a diagnostic is
          // written to stderr (and no error is thrown).
          expect(() => logTracer.endSubsegment(sub), returnsNormally);
        },
        stderr: () => captured,
      );

      expect(captured.text, contains('X-Ray context missing'));
    });

    test('currentSegment is set inside run()', () async {
      final segment = tracer.beginSegment();
      Segment? captured;
      await tracer.run(segment, () async {
        captured = tracer.currentSegment;
      });
      expect(captured, isNotNull);
      expect(captured!.name, 'test-svc');
    });

    test('currentSegment propagates across awaits', () async {
      final segment = tracer.beginSegment();
      Segment? inner;
      await tracer.run(segment, () async {
        await Future.delayed(Duration.zero);
        inner = tracer.currentSegment;
      });
      expect(inner, isNotNull);
    });

    test('nested run() calls are independently zoned', () async {
      final seg1 = tracer.beginSegment();
      final seg2 = tracer.beginSegment();
      Segment? captured1;
      Segment? captured2;

      await Future.wait([
        tracer.run(seg1, () async {
          await Future.delayed(const Duration(milliseconds: 10));
          captured1 = tracer.currentSegment;
        }),
        tracer.run(seg2, () async {
          await Future.delayed(const Duration(milliseconds: 10));
          captured2 = tracer.currentSegment;
        }),
      ]);

      expect(captured1!.id, seg1.id);
      expect(captured2!.id, seg2.id);
    });
  });

  group('XRayTracer — subsegments', () {
    test('beginSubsegment / endSubsegment attaches to sent segment', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final sub = tracer.beginSubsegment('my-op', namespace: 'local');
        await Future.delayed(Duration.zero);
        tracer.endSubsegment(sub);
      });

      expect(sender.lastSubs, hasLength(1));
      expect((sender.lastSubs.first as Map)['name'], 'my-op');
    });

    test('failSubsegment records fault on the subsegment', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final sub = tracer.beginSubsegment('failing-op');
        tracer.failSubsegment(sub, Exception('boom'));
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['fault'], isTrue);
      final cause = sub['cause'] as Map;
      expect((cause['exceptions'] as List).first['message'], contains('boom'));
    });

    test('multiple subsegments all appear in sent segment', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        for (final name in ['a', 'b', 'c']) {
          final sub = tracer.beginSubsegment(name);
          tracer.endSubsegment(sub);
        }
      });

      expect(sender.lastSubs, hasLength(3));
      final names = sender.lastSubs.map((s) => (s as Map)['name']).toList();
      expect(names, containsAll(['a', 'b', 'c']));
    });
  });

  group('XRayTracer — segment lifecycle', () {
    test('segment is sent after run() completes', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        expect(sender.isEmpty, isTrue); // not yet sent
      });
      expect(sender.sent, hasLength(1));
    });

    test('segment is sent even when run() throws', () async {
      final segment = tracer.beginSegment();
      await expectLater(
        () => tracer.run(segment, () async => throw Exception('fail')),
        throwsException,
      );
      expect(sender.sent, hasLength(1));
    });

    test('sent segment has end_time and no in_progress', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {});
      expect(sender.last.containsKey('end_time'), isTrue);
      expect(sender.last.containsKey('in_progress'), isFalse);
    });

    test('beginSegment uses tracer serviceName', () {
      final seg = tracer.beginSegment();
      expect(seg.name, 'test-svc');
    });

    test('beginSegment generates unique trace IDs', () {
      final ids =
          List.generate(20, (_) => tracer.beginSegment().traceId.toString());
      expect(ids.toSet(), hasLength(20));
    });
  });

  group('XRayTracer — sampling', () {
    test('segments are not sent when sampling rate is 0', () async {
      final neverTracer = XRayTracer(
        serviceName: 'svc',
        sender: sender,
        sampling: FixedRateSampler(0.0),
      );
      final segment = neverTracer.beginSegment();
      await neverTracer.run(segment, () async {});
      expect(sender.isEmpty, isTrue);
    });

    test('segments are always sent when sampling rate is 1', () async {
      for (var i = 0; i < 5; i++) {
        final seg = tracer.beginSegment();
        await tracer.run(seg, () async {});
      }
      expect(sender.sent, hasLength(5));
    });
  });

  group('XRayTracer — captureAsync nesting', () {
    test('nests a child subsegment under the captured scope', () async {
      await tracer.run(tracer.beginSegment(), () async {
        await tracer.captureAsync('outer', (span) async {
          final inner = tracer.beginSubsegment('inner');
          tracer.endSubsegment(inner);
        });
      });

      expect(sender.lastSubs, hasLength(1));
      final outer = sender.lastSubs.first as Map;
      expect(outer['name'], 'outer');
      final children = outer['subsegments'] as List?;
      expect(children, hasLength(1));
      expect((children!.first as Map)['name'], 'inner');
    });

    test('nests a child closed after an await (cross-microtask)', () async {
      await tracer.run(tracer.beginSegment(), () async {
        await tracer.captureAsync('outer', (span) async {
          final inner = tracer.beginSubsegment('inner');
          await Future.delayed(Duration.zero);
          tracer.endSubsegment(inner);
        });
      });

      final outer = sender.lastSubs.first as Map;
      expect((outer['subsegments'] as List).first['name'], 'inner');
    });

    test('nests recursively (captureAsync inside captureAsync)', () async {
      await tracer.run(tracer.beginSegment(), () async {
        await tracer.captureAsync('a', (s) async {
          await tracer.captureAsync('b', (s2) async {});
        });
      });

      final a = sender.lastSubs.first as Map;
      expect(a['name'], 'a');
      expect(((a['subsegments'] as List).first as Map)['name'], 'b');
    });

    test('parallel captureAsync calls are siblings, not nested', () async {
      await tracer.run(tracer.beginSegment(), () async {
        await Future.wait([
          tracer.captureAsync('a', (s) async {
            await Future.delayed(const Duration(milliseconds: 10));
          }),
          tracer.captureAsync('b', (s) async {
            await Future.delayed(const Duration(milliseconds: 10));
          }),
        ]);
      });

      final subs = sender.lastSubs;
      expect(subs, hasLength(2));
      expect(subs.map((s) => (s as Map)['name']).toSet(), {'a', 'b'});
      // Neither nests the other — the bug a naive shared "current" pointer
      // would introduce.
      for (final s in subs) {
        expect((s as Map).containsKey('subsegments'), isFalse);
      }
    });

    test('returns the body result', () async {
      final result = await tracer.run(tracer.beginSegment(), () async {
        return await tracer.captureAsync('op', (s) async => 42);
      });
      expect(result, 42);
    });

    test('records a fault when the body throws', () async {
      await tracer.run(tracer.beginSegment(), () async {
        await expectLater(
          () => tracer.captureAsync('boom', (s) async => throw Exception('x')),
          throwsException,
        );
      });
      final sub = sender.lastSubs.first as Map;
      expect(sub['name'], 'boom');
      expect(sub['fault'], isTrue);
    });

    test('outside a run() zone the body runs untraced (fail-open)', () async {
      final result = await tracer.captureAsync('op', (s) async => 7);
      expect(result, 7);
      expect(sender.isEmpty, isTrue);
    });
  });

  group('XRayTracer — live annotations & metadata', () {
    test('captureAsync span annotation/metadata land on the subsegment',
        () async {
      await tracer.run(tracer.beginSegment(), () async {
        await tracer.captureAsync('op', (span) async {
          span.annotate('k', 'v');
          span.addMetadata('m', 1, namespace: 'ns');
        });
      });

      final sub = sender.lastSubs.first as Map;
      expect((sub['annotations'] as Map)['k'], 'v');
      expect(((sub['metadata'] as Map)['ns'] as Map)['m'], 1);
    });

    test('tracer.annotate at root level annotates the segment', () async {
      await tracer.run(tracer.beginSegment(), () async {
        tracer.annotate('env', 'prod');
        tracer.addMetadata('build', 7);
      });

      expect((sender.last['annotations'] as Map)['env'], 'prod');
      expect(((sender.last['metadata'] as Map)['default'] as Map)['build'], 7);
    });

    test('tracer.annotate inside captureAsync targets the inner scope',
        () async {
      await tracer.run(tracer.beginSegment(), () async {
        await tracer.captureAsync('op', (span) async {
          tracer.annotate('inner', true);
        });
      });

      // Annotation is on the subsegment, not the segment.
      expect(sender.last.containsKey('annotations'), isFalse);
      final sub = sender.lastSubs.first as Map;
      expect((sub['annotations'] as Map)['inner'], true);
    });

    test('span.setError marks the subsegment as error with a cause', () async {
      await tracer.run(tracer.beginSegment(), () async {
        await tracer.captureAsync('op', (span) async {
          span.setError(Exception('bad'));
        });
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['error'], isTrue);
      expect(sub['cause'], isNotNull);
    });

    test('tracer.annotate sanitizes an invalid key into the sent segment',
        () async {
      await tracer.run(tracer.beginSegment(), () async {
        tracer.annotate('order.id', 'A1');
      });

      final annotations = sender.last['annotations'] as Map;
      expect(annotations.containsKey('order.id'), isFalse);
      expect(annotations['order_id'], 'A1');
    });

    test('tracer.annotate coerces a non-scalar value in the sent segment',
        () async {
      await tracer.run(tracer.beginSegment(), () async {
        tracer.annotate('items', [1, 2, 3]);
      });

      expect((sender.last['annotations'] as Map)['items'], '[1, 2, 3]');
    });

    test('captureAsync span.annotate sanitizes the key on the subsegment',
        () async {
      await tracer.run(tracer.beginSegment(), () async {
        await tracer.captureAsync('op', (span) async {
          span.annotate('bad key', 'v');
        });
      });

      final sub = sender.lastSubs.first as Map;
      expect((sub['annotations'] as Map)['bad_key'], 'v');
    });
  });

  group('XRayTracer — segment fault on uncaught error', () {
    test('an uncaught error in run() marks the segment as fault', () async {
      await expectLater(
        () => tracer.run(tracer.beginSegment(), () async {
          throw Exception('boom');
        }),
        throwsException,
      );
      expect(sender.last['fault'], isTrue);
      expect(sender.last['cause'], isNotNull);
    });
  });
}
