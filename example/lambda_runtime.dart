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
// 2. Read AWS_XRAY_DAEMON_ADDRESS at cold start.
//    Lambda injects this env var.  Newer runtimes use 169.254.100.1:2000
//    (link-local), NOT 127.0.0.1:2000.
//
// 3. Call XRay.patchHttp() exactly once at cold start.
//    Double-patching wraps XRayHttpClient inside itself, producing
//    duplicate subsegments for every outbound HTTP request.
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
import 'package:http/http.dart' as http;

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
  final raw =
      Platform.environment['AWS_XRAY_DAEMON_ADDRESS'] ?? '127.0.0.1:2000';
  final colon = raw.lastIndexOf(':');
  final host = colon == -1 ? raw : raw.substring(0, colon);
  final port = int.tryParse(raw.substring(colon + 1)) ?? 2000;

  _tracer = XRayTracer(
    serviceName:
        Platform.environment['AWS_LAMBDA_FUNCTION_NAME'] ?? 'my-function',
    sender: sender ?? UdpSender(host: host, port: port),
    sampling: FixedRateSampler(1.0),
  );

  XRay.patchHttp(_tracer);
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
    parentId!,
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
  // patchHttp() is active, so this http.Client() is backed by an
  // XRayHttpClient. XRayBaseClient automatically suppresses that inner patch
  // for the duration of the send, so the request is traced exactly once (the
  // rich AWS subsegment below), not duplicated as a bare host-named one.
  final client = XRayBaseClient(http.Client(), _tracer);
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
