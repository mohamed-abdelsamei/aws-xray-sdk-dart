// Example: hearing about problems the SDK contains instead of throwing.
//
// Tracing never breaks your app, so some failures would otherwise leave no
// signal. XRay.configure() accepts three hooks, passed to the tracer it builds
// (they are ignored when you supply `tracer:`):
//   • onDiagnostic  — a contained problem: node_trimmed, adapter_failed,
//                     daemon_address_invalid. `code` is an open string.
//   • onSendError   — a sampled segment could not be sent (local failure).
//   • onSampledDrop — a segment was dropped because the trace was not sampled.
//
// This example triggers two diagnostics without a daemon:
//   1. node_trimmed   — one segment carries a ~100 KB metadata value, too big
//                       for a single UDP datagram, so the encoder trims it.
//                       This goes through the default UdpSender, which fires a
//                       datagram at the daemon address (127.0.0.1:2000 unless
//                       AWS_XRAY_DAEMON_ADDRESS is set). With nothing listening
//                       the datagram is dropped silently, so no daemon is
//                       needed.
//   2. adapter_failed — a registered Smithy requestAdapter throws. The call
//                       still succeeds; the hook just hears about it.
//
// The hooks are synchronous and must not throw. Log or count inside them; do
// not do async work. In production, rate-limit — node_trimmed can fire often.
// `d.error` is the raw thrown object and is not redacted, so treat it as
// sensitive if you log it.

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

/// Samples every other trace so onSampledDrop fires deterministically.
class _AlternatingSampler implements SamplingStrategy {
  int _n = 0;
  @override
  bool shouldSample(SamplingRequest request) => _n++ % 2 == 0;
}

/// Minimal stand-in for a Smithy client: it exposes its send function so
/// `rebuild` can swap in the wrapped one (see aws_sdk_tracing.dart).
class _StubClient {
  _StubClient([Future<String> Function(String)? send])
      : _send = send ?? ((req) async => 'pong');
  final Future<String> Function(String) _send;
  Future<String> ping() => _send('ping');
}

Future<void> main() async {
  XRay.configure(
    serviceName: 'diagnostics-demo',
    sampling: _AlternatingSampler(),
    patchDartIoHttp: false, // no real HTTP in this example
    onDiagnostic: (d) => print('diagnostic  [${d.code}] ${d.message}'
        '${d.error != null ? '  error=${d.error}' : ''}'),
    onSendError: (segment, error) =>
        print('send error  ${segment.name}: $error'),
    onSampledDrop: (segment) => print('sampled out ${segment.name}'),
  );

  // 1. node_trimmed (sampled: first trace). The oversized metadata value is
  //    replaced with "[truncated: N bytes]" so the datagram fits.
  await XRay.trace('oversized', () async {
    XRay.metadata('payload', 'x' * 100000);
  });

  // 2. onSampledDrop (second trace is not sampled, nothing is sent).
  await XRay.trace('not-sampled', () async {});

  // 3. adapter_failed (third trace, sampled). The requestAdapter throws; the
  //    interceptor reports it and the call still returns normally.
  XRay.registerClient<_StubClient>(
    requestAdapter: (req) => throw StateError('adapter bug'),
    responseAdapter: (res) => (
      statusCode: 200,
      contentLength: null,
      requestId: null,
      region: null,
      errorCode: null,
    ),
    rebuild: (client, wrapSend) {
      final wrapped = wrapSend((req) => client._send(req as String));
      return _StubClient((req) async => await wrapped(req) as String);
    },
  );
  final client = XRay.fromClient(_StubClient(), tracer: XRay.tracer);
  await XRay.trace('adapter', () async {
    print('call result: ${await client.ping()}');
  });

  XRay.reset();
}
