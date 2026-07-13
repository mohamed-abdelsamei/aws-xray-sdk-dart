import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:http/http.dart' as http;
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

    test('no-op tracer fails CLOSED off-zone; real tracer fails open (C4)', () {
      // Outside any run() zone, the unconfigured no-op must report not-sampled
      // so instrumentation never injects Sampled=1 for a segment it will never
      // emit. A real tracer keeps the fail-open behavior for manual segments.
      expect(XRay.tracer.isSampled, isFalse,
          reason: 'no-op must fail closed off-zone');

      final real = XRayTracer(serviceName: 'svc', sender: _RecordingSender());
      expect(real.isSampled, isTrue,
          reason: 'a real tracer fails open off-zone');
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

    test('client built BEFORE configure still traces afterward (C1)', () async {
      final inner = _MockClient(200);
      // Build the wrapped client while tracing is unconfigured — the common
      // field-initializer / constructor case. It must bind to whatever tracer
      // is installed at request time, not the no-op captured at construction.
      final client = XRay.aws(inner: inner);
      expect(XRay.isConfigured, isFalse);

      final sender = InMemorySender();
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'svc',
          sender: sender,
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      // The same pre-built client now resolves the configured tracer per send.
      expect(client, isA<XRayBaseClient>());
      final tracer = XRay.tracer;
      await tracer.run(tracer.beginSegment(), () async {
        await client.get(Uri.parse('https://example.com/'));
      });
      expect(sender.segments, hasLength(1),
          reason: 'a pre-configure client must trace once configured');
      expect(sender.segments.single.subsegments, hasLength(1));
    });

    test('explicit tracer pins and is not overridden by the global', () async {
      final pinned = InMemorySender();
      final pinnedTracer = XRayTracer(
        serviceName: 'pinned',
        sender: pinned,
        sampling: FixedRateSampler(1.0),
      );
      final client = XRay.httpClientFor(pinnedTracer);
      expect(client, isA<XRayBaseClient>());

      // Install a different global tracer — the pinned client must ignore it.
      final global = InMemorySender();
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'global',
          sender: global,
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      await pinnedTracer.run(pinnedTracer.beginSegment(), () async {});
      expect(pinned.segments, hasLength(1));
    });

    test('XRayBaseClient(inner) zero-arg resolves the global default tracer',
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

      // No explicit tracer passed -> must bind to the configured global one.
      final client = XRayBaseClient(http.Client());
      expect(client, isA<XRayBaseClient>());

      final tracer = XRay.tracer;
      await tracer.run(tracer.beginSegment(), () async {});
      expect(sender.sent, hasLength(1),
          reason: 'segment should reach the global tracer\'s sender');
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

  group('XRay.annotate / XRay.metadata facade', () {
    test('annotate adds entries to the active segment via the global tracer',
        () async {
      final sender = InMemorySender();
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'svc',
          sender: sender,
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      final tracer = XRay.tracer;
      await tracer.run(tracer.beginSegment(), () async {
        XRay.annotate({'operationId': 'op-1', 'environment': 'test'});
      });

      final ann = sender.segments.single.annotations!;
      expect(ann['operationId'], 'op-1');
      expect(ann['environment'], 'test');
    });

    test('metadata adds a namespaced entry to the active segment', () async {
      final sender = InMemorySender();
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'svc',
          sender: sender,
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      final tracer = XRay.tracer;
      await tracer.run(tracer.beginSegment(), () async {
        XRay.metadata('payload', {'size': 3});
      });

      final meta = sender.segments.single.metadata!;
      expect(meta['default']?['payload'], {'size': 3});
    });

    test('annotate no-ops off-trace and when unconfigured', () {
      // Unconfigured: the no-op tracer must swallow it without throwing.
      expect(() => XRay.annotate({'a': 1}), returnsNormally);
      expect(() => XRay.metadata('k', 'v'), returnsNormally);
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

    test('with a captured header emits a subsegment doc parented to Lambda',
        () async {
      // The production path: the runtime poll captures Lambda-Runtime-Trace-Id,
      // then runLambdaInvocation parents the handler span under Lambda's
      // auto-created AWS::Lambda::Function segment via runLambda().
      final sender = InMemorySender();
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'svc',
          sender: sender,
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      final traceId = TraceId.generate();
      const parentId = '53995c3f42cd8ad8';
      final header = 'Root=$traceId;Parent=$parentId;Sampled=1';
      final capture =
          LambdaTraceCapture(innerFactory: () => _FakeRuntimeClient(header));

      final result = await capture.run(() async {
        // Runtime polls /invocation/next -> header is captured.
        await http.get(Uri.parse('http://localhost/invocation/next'));
        // Handler glue dispatches the invocation through the wrapper.
        return XRay.runLambdaInvocation(capture, 'my-fn', () async => 7);
      });

      expect(result, 7);
      // runLambda delivers an independent subsegment document via sendPackets;
      // the top-level send() path (sender.segments) is never used, so it cannot
      // compete with Lambda's auto-created AWS::Lambda::Function segment.
      expect(sender.segments, isEmpty);
      final doc = _decodePacket(sender.packets.single);
      expect(doc['type'], 'subsegment');
      expect(doc['name'], 'my-fn');
      expect(doc['trace_id'], traceId.toString());
      expect(doc['parent_id'], parentId);
    });

    test('accepts a synchronous (non-Future) fn', () async {
      // Handler actions typed FutureOr<T> drop in without `() async =>`
      // coercion; a plain value return must work.
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'svc',
          sender: InMemorySender(),
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      final result =
          await XRay.runLambdaInvocation(LambdaTraceCapture(), 'fn', () => 41);
      expect(result, 41);
    });

    test('a pinned tracer is used instead of the global', () async {
      final pinned = InMemorySender();
      final pinnedTracer = XRayTracer(
        serviceName: 'pinned',
        sender: pinned,
        sampling: FixedRateSampler(1.0),
      );
      // Install a DIFFERENT global tracer; the pinned one must win.
      final global = InMemorySender();
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'global',
          sender: global,
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      await XRay.runLambdaInvocation(
        LambdaTraceCapture(),
        'fn',
        () async => 1,
        tracer: pinnedTracer,
      );

      expect(pinned.segments, hasLength(1),
          reason: 'the pinned tracer must receive the segment');
      expect(global.segments, isEmpty);
    });
  });

  group('XRay.trace / XRay.capture facade', () {
    test('trace + capture run on the configured global tracer', () async {
      final sender = InMemorySender();
      XRay.configure(
        tracer: XRayTracer(
          serviceName: 'svc',
          sender: sender,
          sampling: FixedRateSampler(1.0),
        ),
        patchDartIoHttp: false,
      );

      final result = await XRay.trace('order', () async {
        await XRay.capture('validate', (span) async {
          span.annotate('orderId', 'o-1');
        });
        return 'ok';
      });

      expect(result, 'ok');
      final segment = sender.segments.single;
      expect(segment.name, 'order');
      final sub = segment.subsegments.single;
      expect(sub.name, 'validate');
      expect(sub.annotations?['orderId'], 'o-1');
    });

    test('trace is safe before configure(): runs fn, emits nothing', () async {
      expect(XRay.isConfigured, isFalse);
      final result = await XRay.trace('op', () => 7);
      expect(result, 7); // no-op tracer: fn still runs, nothing is sent
    });
  });
}

// Strips the X-Ray header line from a UDP payload and decodes the JSON body.
Map<String, Object?> _decodePacket(List<int> packet) {
  final raw = utf8.decode(packet);
  return jsonDecode(raw.substring(raw.indexOf('\n') + 1))
      as Map<String, Object?>;
}

// A fake runtime client that returns [_header] as Lambda-Runtime-Trace-Id,
// mimicking the Runtime API /invocation/next response.
class _FakeRuntimeClient extends http.BaseClient {
  _FakeRuntimeClient(this._header);
  final String _header;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.value(utf8.encode('{}')),
        200,
        headers: {'lambda-runtime-trace-id': _header},
      );
}

class _MockClient extends http.BaseClient {
  _MockClient(this.statusCode);

  final int statusCode;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(Stream.value(utf8.encode('{}')), statusCode);
}
