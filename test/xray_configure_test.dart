import 'dart:convert';

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
}

void main() {
  // Each test starts from a clean global state and restores it afterward, since
  // XRay.tracer / configure mutate process-wide state.
  tearDown(XRay.reset);

  group('XRay global default tracer', () {
    test('is a no-op until configured: discards segments, isConfigured false',
        () {
      expect(XRay.isConfigured, isFalse);
      // The no-op tracer must be usable without throwing.
      final tracer = XRay.tracer;
      expect(tracer, isNotNull);
      expect(() => tracer.beginSegment(), returnsNormally);
    });

    test('tracer setter installs and clears the global', () {
      final mine = XRayTracer(serviceName: 'svc', sender: _RecordingSender());
      XRay.tracer = mine;
      expect(XRay.isConfigured, isTrue);
      expect(identical(XRay.tracer, mine), isTrue);

      XRay.tracer = null;
      expect(XRay.isConfigured, isFalse);
    });
  });

  group('XRay.configure', () {
    test('installs a tracer and is idempotent', () {
      final first = XRay.configure(
        tracer: XRayTracer(serviceName: 'svc', sender: _RecordingSender()),
        patchDartIoHttp: false,
      );
      expect(XRay.isConfigured, isTrue);

      // A second call is a no-op and returns the same instance.
      final second = XRay.configure(
        tracer: XRayTracer(serviceName: 'other', sender: _RecordingSender()),
        patchDartIoHttp: false,
      );
      expect(identical(first, second), isTrue);
    });

    test('explicit serviceName overrides the env-derived default', () {
      final t = XRay.configure(
        serviceName: 'my-service',
        fromEnv: false,
        patchDartIoHttp: false,
      );
      expect(t.serviceName, 'my-service');
    });

    test('falls back to a default service name without env', () {
      final t = XRay.configure(fromEnv: false, patchDartIoHttp: false);
      expect(t.serviceName, 'dart-service');
    });

    test('reset returns to the unconfigured no-op state', () {
      XRay.configure(
          serviceName: 'svc', fromEnv: false, patchDartIoHttp: false);
      expect(XRay.isConfigured, isTrue);
      XRay.reset();
      expect(XRay.isConfigured, isFalse);
    });
  });

  group('XRay.aws / httpClientFor', () {
    test('aws() wraps a client that traces under the configured tracer',
        () async {
      final sender = _RecordingSender();
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'svc',
          sender: sender,
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      final client = XRay.aws();
      expect(client, isA<XRayBaseClient>());

      // Outside a run zone there is no segment, so it passes through untraced;
      // inside a run zone it should record a subsegment. We assert the wiring by
      // running a traced segment and confirming the sender receives it.
      final tracer = XRay.tracer;
      await tracer.run(tracer.beginSegment(), () async {
        // No real network call here; just confirm the client is the traced type
        // bound to the global tracer (full request tracing is covered in
        // xray_base_client_test.dart).
      });
      expect(sender.sent, hasLength(1));
    });
  });

  group('tracer.annotateAll', () {
    test('adds every entry to the active segment', () async {
      final sender = _RecordingSender();
      final tracer = XRayTracer(
        serviceName: 'svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
      );

      await tracer.run(tracer.beginSegment(), () async {
        tracer.annotateAll({'a': 1, 'b': 'two', 'c': true});
      });

      final ann = sender.sent.single['annotations'] as Map<String, Object?>;
      expect(ann['a'], 1);
      expect(ann['b'], 'two');
      expect(ann['c'], true);
    });

    test('drops the batch when there is no active trace', () {
      final tracer = XRayTracer(serviceName: 'svc', sender: _RecordingSender());
      // No run zone — must not throw (default ignore policy).
      expect(() => tracer.annotateAll({'a': 1}), returnsNormally);
    });
  });

  group('XRay.runLambdaInvocation', () {
    test('with no captured header starts a fresh top-level segment', () async {
      final sender = _RecordingSender();
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'svc',
          sender: sender,
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      // A capture that never saw a header -> fresh-segment path.
      final capture = LambdaTraceCapture();
      final result = await XRay.runLambdaInvocation(
        capture,
        'my-fn',
        () async => 42,
      );

      expect(result, 42);
      final seg = sender.sent.single;
      expect(seg['name'], 'my-fn');
      expect(seg['origin'], 'AWS::Lambda::Function');
      // A top-level segment has no parent_id (not a Lambda subsegment doc).
      expect(seg.containsKey('parent_id'), isFalse);
    });
  });
}
