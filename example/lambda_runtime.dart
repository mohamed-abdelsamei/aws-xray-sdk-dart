// Example: AWS Lambda custom runtime with X-Ray tracing.
//
// Demonstrates the complete cold-start setup and per-invocation tracing
// pattern for a Dart Lambda using the provided:al2023 base image.
//
// KEY POINTS
//
// 1. Use XRayTracer.runLambda() instead of run().
//    provided:al2023 automatically creates and sends an AWS::Lambda::Function
//    segment.  If the SDK also sends a top-level segment, the daemon receives
//    two competing segments and silently drops ours.
//    runLambda() emits an independent *subsegment document* parented to
//    Lambda's auto-created segment, so both appear correctly in X-Ray.
//
// 2. Read AWS_XRAY_DAEMON_ADDRESS at runtime.
//    Lambda injects the daemon address via this env var.  Newer Lambda
//    environments use 169.254.100.1:2000 (link-local), NOT 127.0.0.1:2000.
//    Hardcoding the address causes all UDP packets to be silently dropped.
//
// 3. Call XRay.patchHttp() exactly once at cold start.
//    Calling it twice wraps XRayHttpClient inside itself, producing duplicate
//    subsegments for every outbound HTTP request.
//
// RESULTING X-RAY TRACE
//
//   AWS::Lambda (facade)                    [auto]
//     AWS::Lambda::Function                 [auto — id from Parent= in header]
//       Overhead                            [auto]
//       <function-name>                     ← our handler subsegment ✓
//         parse-input                       ← manual subsegment
//         jsonplaceholder.typicode.com      ← auto-traced, namespace=remote
//
// HOW TO BUILD AND DEPLOY
//
//   # From the workspace root (xray_client/)
//   docker build -f demos/lambda/Dockerfile -t xray-lambda-demo .
//   # Push to ECR and update the Lambda function image, or use CDK/SAM.

import 'dart:convert';
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

// ── Cold-start helpers ────────────────────────────────────────────────────────

/// Parses the X-Ray daemon address from AWS_XRAY_DAEMON_ADDRESS.
///
/// Lambda injects this env var.  The format is `host:port`.
/// Falls back to 127.0.0.1:2000 when running outside Lambda.
(String host, int port) _daemonAddress() {
  final raw =
      Platform.environment['AWS_XRAY_DAEMON_ADDRESS'] ?? '127.0.0.1:2000';
  final colon = raw.lastIndexOf(':');
  if (colon == -1) return (raw, 2000);
  return (
    raw.substring(0, colon),
    int.tryParse(raw.substring(colon + 1)) ?? 2000
  );
}

// ── Cold start ────────────────────────────────────────────────────────────────
//
// Everything here runs once per Lambda sandbox lifetime.

Future<void> main() async {
  // 1. Initialise the X-Ray tracer with the correct daemon address.
  final (host, port) = _daemonAddress();
  final tracer = XRayTracer(
    serviceName:
        Platform.environment['AWS_LAMBDA_FUNCTION_NAME'] ?? 'my-function',
    sender: UdpSender(host: host, port: port),
    // Lambda has already decided sampling (Sampled= in the trace header).
    // Always forward to the local daemon at rate 1.0; the daemon enforces it.
    sampling: FixedRateSampler(1.0),
  );

  stderr.writeln('[cold-start] tracer daemon=$host:$port');

  // 2. Patch dart:io ONCE so every HttpClient is automatically traced.
  XRay.patchHttp(tracer);

  // 3. Start the Lambda Runtime API event loop.
  final runtimeApi =
      Platform.environment['AWS_LAMBDA_RUNTIME_API'] ?? 'localhost:9001';
  final client = HttpClient(); // not traced — created before runLambda zone

  while (true) {
    // ── Poll for next invocation ────────────────────────────────────────────
    final nextReq = await client.getUrl(
        Uri.parse('http://$runtimeApi/2018-06-01/runtime/invocation/next'));
    final nextRes = await nextReq.close();

    final requestId =
        nextRes.headers.value('lambda-runtime-aws-request-id') ?? '';
    final rawHeader = nextRes.headers.value('lambda-runtime-trace-id') ?? '';
    // deadlineMs available for timeout enforcement if needed:
    // int.tryParse(nextRes.headers.value('lambda-runtime-deadline-ms') ?? '')

    final event =
        jsonDecode(await utf8.decodeStream(nextRes)) as Map<String, Object?>? ??
            const {};

    stderr.writeln('[invoke] requestId=$requestId traceHeader=$rawHeader');

    // ── Parse the Lambda-Runtime-Trace-Id header ────────────────────────────
    // Root=   → the X-Ray trace ID for this invocation
    // Parent= → the id of the auto-created AWS::Lambda::Function segment
    // Sampled=1/0 → Lambda's sampling decision
    final traceId = TraceId.tryParse(rawHeader) ?? TraceId.generate();
    final parentId = TraceId.parseParentId(rawHeader);
    final sampled = TraceId.parseSampled(rawHeader) ?? true;

    // ── Handle + trace ──────────────────────────────────────────────────────
    try {
      final result = parentId != null
          // Normal Lambda execution: emit a subsegment document parented to
          // the auto-created AWS::Lambda::Function segment (id = parentId).
          ? await tracer.runLambda(
              traceId,
              parentId,
              tracer.serviceName,
              () => _handleEvent(event, tracer),
              sampled: sampled,
            )
          // Fallback for local testing (no Lambda runtime context).
          : await tracer.run(
              Segment.begin(
                name: tracer.serviceName,
                traceId: traceId,
                origin: 'AWS::Lambda::Function',
              ),
              () => _handleEvent(event, tracer),
            );

      // ── Post success response ─────────────────────────────────────────────
      final resReq = await client.postUrl(
        Uri.parse(
            'http://$runtimeApi/2018-06-01/runtime/invocation/$requestId/response'),
      );
      resReq.headers.contentType = ContentType.json;
      final resBody = utf8.encode(jsonEncode(result));
      resReq.contentLength = resBody.length;
      resReq.add(resBody);
      await resReq.close();
    } catch (e, st) {
      // ── Post error response ───────────────────────────────────────────────
      stderr.writeln('[invoke] error: $e\n$st');
      final errReq = await client.postUrl(
        Uri.parse(
            'http://$runtimeApi/2018-06-01/runtime/invocation/$requestId/error'),
      );
      errReq.headers
        ..set('Lambda-Runtime-Function-Error-Type', 'Runtime.${e.runtimeType}')
        ..contentType = ContentType.json;
      final errBody = utf8.encode(jsonEncode({
        'errorMessage': e.toString(),
        'errorType': e.runtimeType.toString(),
      }));
      errReq.contentLength = errBody.length;
      errReq.add(errBody);
      await errReq.close();
    }
  }
}

// ── Handler ───────────────────────────────────────────────────────────────────

/// Processes an API Gateway proxy event and returns a proxy response.
///
/// The two subsegments produced here appear in X-Ray under the handler
/// subsegment emitted by runLambda():
///
///   <function-name>
///     parse-input       ← manual subsegment
///     jsonplaceholder…  ← auto-traced HTTP, namespace=remote
Future<Map<String, Object?>> _handleEvent(
  Map<String, Object?> event,
  XRayTracer tracer,
) async {
  // ── 1. Parse input (manual subsegment) ────────────────────────────────────
  final inputSub = tracer.beginSubsegment('parse-input');
  final String? userId;
  try {
    final params = event['pathParameters'] as Map<String, Object?>?;
    userId = params?['userId'] as String?;
    if (userId == null) {
      tracer.failSubsegment(inputSub, 'missing pathParameters.userId');
      return _apiResponse(400, body: {'error': 'missing userId'});
    }
    tracer.endSubsegment(inputSub.addMetadata('userId', userId));
  } catch (e) {
    tracer.failSubsegment(inputSub, e);
    rethrow;
  }

  // ── 2. Upstream HTTP call (auto-traced by XRayHttpClient) ─────────────────
  // No manual subsegment needed — XRay.patchHttp() already intercepts this.
  // The subsegment is named 'jsonplaceholder.typicode.com', namespace='remote'.
  // If the host were *.amazonaws.com the namespace would be 'aws' automatically.
  final httpClient = HttpClient();
  try {
    final uri = Uri.parse('https://jsonplaceholder.typicode.com/users/$userId');
    final req = await httpClient.getUrl(uri);
    final res = await req.close();
    if (res.statusCode == 404) {
      return _apiResponse(404, body: {'error': 'user $userId not found'});
    }
    final body =
        jsonDecode(await utf8.decodeStream(res)) as Map<String, Object?>;
    return _apiResponse(200, body: body);
  } finally {
    httpClient.close();
  }
}

Map<String, Object?> _apiResponse(int status,
        {required Map<String, Object?> body}) =>
    {
      'statusCode': status,
      'headers': {'Content-Type': 'application/json'},
      'body': jsonEncode(body),
    };
