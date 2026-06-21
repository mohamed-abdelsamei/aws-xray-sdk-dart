// Example: AWS Lambda handler with X-Ray tracing.
//
// Runs a simulated Lambda invocation locally — no daemon required.
// The traced segment document is printed to stdout for inspection.
//
// KEY POINTS
//
// 1. Use runLambda() instead of run().
//    provided:al2023 automatically creates a top-level AWS::Lambda::Function
//    segment.  If the SDK also sends one, the daemon silently drops ours.
//    runLambda() emits an independent subsegment document parented to
//    Lambda's auto-created segment, so both appear correctly in X-Ray.
//
// 2. Call XRay.configure() once at cold start.
//    It reads AWS_XRAY_DAEMON_ADDRESS (newer runtimes use the link-local
//    169.254.100.1:2000, NOT 127.0.0.1:2000) and AWS_LAMBDA_FUNCTION_NAME,
//    installs the process-wide default tracer, and patches dart:io HTTP — in
//    one idempotent call. (In a real runtime, capture the trace header with
//    LambdaTraceCapture and use XRay.runLambdaInvocation; this local example
//    feeds a simulated header string directly to runLambda.)
//
// RESULTING X-RAY TRACE
//
//   AWS::Lambda (facade)                    [auto]
//     AWS::Lambda::Function                 [auto — id from Parent= header]
//       Overhead                            [auto]
//       my-function                         ← runLambda() subsegment ✓
//         validate-input                    ← manual subsegment, namespace=aws
//         jsonplaceholder.typicode.com      ← auto-traced HTTP, namespace=remote
//         DynamoDB                          ← XRayBaseClient, namespace=aws,
//                                             operation=PutItem (traced once)

import 'dart:convert';
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

// ── Run locally ──────────────────────────────────────────────────────────────

void main() async {
  // Use NoopSender for local runs — swap for UdpSender() when deploying.
  await coldStart(sender: NoopSender());

  final event = {
    'pathParameters': {'userId': '1'},
  };

  // Simulate the Lambda-Runtime-Trace-Id header that API Gateway would send.
  final header =
      'Root=${TraceId.generate()};Parent=${_fakeParentId()};Sampled=1';

  final result = await handleInvocation(event, header);
  print('Result: ${result['statusCode']}');
}

String _fakeParentId() {
  // Generate a realistic 16-hex-char segment id.
  final bytes =
      List<int>.generate(8, (_) => DateTime.now().microsecondsSinceEpoch % 256);
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// ── Cold start (runs once per sandbox lifetime) ──────────────────────────────

late final XRayTracer _tracer;

Future<void> coldStart({Sender? sender}) async {
  // XRay.configure() parses AWS_XRAY_DAEMON_ADDRESS (IPv6-safe) and
  // AWS_LAMBDA_FUNCTION_NAME, installs the global tracer, and patches HTTP.
  // It is idempotent, so calling it again per sandbox is a no-op.
  //
  // In production you would call simply `XRay.configure();`. Here we pass an
  // explicit tracer so the example can use NoopSender + always-on sampling for
  // a deterministic local run.
  _tracer = XRay.configure(
    tracer: XRayTracer(
      serviceName:
          Platform.environment['AWS_LAMBDA_FUNCTION_NAME'] ?? 'my-function',
      sender: sender ?? UdpSender(),
      sampling: FixedRateSampler(1.0),
    ),
  );
}

// ── Per-invocation handler ──────────────────────────────────────────────────

Future<Map<String, Object?>> handleInvocation(
  Map<String, Object?> event,
  String traceHeader,
) async {
  final traceId = TraceId.tryParse(traceHeader) ?? TraceId.generate();
  final parentId = TraceId.parseParentId(traceHeader);
  final sampled = TraceId.parseSampled(traceHeader) ?? true;

  return _tracer.runLambda(
    traceId,
    // The header may have no Parent= (a trace originating at this service, or a
    // direct/test invocation); runLambda accepts an empty parent id.
    parentId ?? '',
    _tracer.serviceName,
    () => _handler(event),
    sampled: sampled,
  );
}

// ── Business logic ──────────────────────────────────────────────────────────

Future<Map<String, Object?>> _handler(Map<String, Object?> event) async {
  // ── 1. Custom subsegment: validate input ──────────────────────────────────
  final sub = _tracer.beginSubsegment('validate-input', namespace: 'aws');
  final userId = switch (event['pathParameters']) {
    {'userId': final String uid} => uid,
    _ => null,
  };
  if (userId == null) {
    _tracer.failSubsegment(sub, 'missing userId');
    return {'statusCode': 400, 'body': '{"error":"missing userId"}'};
  }
  _tracer.endSubsegment(sub.addMetadata('userId', userId));

  // ── 2. HTTP call to external API (auto-traced, namespace=remote) ───────────
  final user = await _fetchUser(userId);

  // ── 3. DynamoDB PutItem call (traced once, namespace=aws) ──────────────────
  //
  // XRay.aws() returns an http.Client wrapped with X-Ray tracing, bound to the
  // global tracer installed by configure(). patchHttp() is active, so the inner
  // http.Client() is backed by an XRayHttpClient; XRayBaseClient suppresses
  // that inner patch during the send, so the request is traced exactly once
  // (the rich AWS subsegment below), not duplicated as a bare host-named one.
  final client = XRay.aws();
  try {
    final body = utf8.encode(jsonEncode({
      'TableName': 'users',
      'Item': {
        'userId': {'S': userId},
        'name': {'S': user['name'] ?? ''},
      },
    }));
    final res = await client.post(
      Uri.parse('https://dynamodb.us-east-1.amazonaws.com'),
      headers: {
        'X-Amz-Target': 'DynamoDB_20120810.PutItem',
        'Content-Type': 'application/x-amz-json-1.0',
      },
      body: body,
    );
    if (res.statusCode != 200) {
      return {
        'statusCode': 502,
        'body': '{"error":"DynamoDB returned ${res.statusCode}"}',
      };
    }
  } finally {
    client.close();
  }

  return {'statusCode': 200, 'body': jsonEncode(user)};
}

Future<Map<String, Object?>> _fetchUser(String userId) async {
  final url = Uri.parse('https://jsonplaceholder.typicode.com/users/$userId');
  final httpClient = HttpClient();
  try {
    final req = await httpClient.getUrl(url);
    final res = await req.close();
    final body =
        jsonDecode(await utf8.decodeStream(res)) as Map<String, Object?>;
    return body;
  } finally {
    httpClient.close();
  }
}
