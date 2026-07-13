// Example: wrapping a Smithy-generated AWS SDK client with X-Ray tracing.
//
// XRay.registerClient<T>() teaches the SDK how to intercept requests for a
// specific client type.  XRay.fromClient<T>() then wraps any instance of that
// type so every call automatically opens a subsegment.
//
// This example traces both a successful and a failing DynamoDB call, then
// prints the subsegments tracing produced — operation, namespace, AWS resource
// data (table/region/request_id), HTTP status, fault + cause, and duration —
// using InMemorySender so the output is visible without a daemon. It shows:
//   • injecting X-Amzn-Trace-Id via withTraceHeader (asserted on the wire)
//   • extracting the table name into aws.* fields via a custom extractor
//   • recording a thrown service error as fault=true + cause
//
// It uses a stub DynamoDbClient so it runs without a real Smithy dependency.
// In your application, replace the stub with the real package:aws_dynamodb_api
// or Smithy-generated client (and drop the explicit `extractor:`, since the
// built-in extractors are keyed by the real client type names).
//
// If you are using a community HTTP-based AWS client (e.g. aws_dynamodb_api
// from pub.dev) you don't need registerClient at all — just call
// XRay.patchHttp(tracer) once at startup and every request to *.amazonaws.com
// is automatically traced with namespace='aws'. See http_tracing.dart.

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

// ---------------------------------------------------------------------------
// Stub types — replace with the real Smithy client in your app.
// ---------------------------------------------------------------------------

typedef SendFn<Req, Res> = Future<Res> Function(Req request);

class GetItemRequest {
  const GetItemRequest({
    required this.tableName,
    required this.key,
    this.headers = const {},
  });
  final String tableName;
  final Map<String, Object?> key;

  /// Outbound headers. The interceptor injects `X-Amzn-Trace-Id` here via the
  /// `withTraceHeader` adapter, the same way a real Smithy request carries it.
  final Map<String, String> headers;

  GetItemRequest withHeaders(Map<String, String> headers) => GetItemRequest(
        tableName: tableName,
        key: key,
        headers: {...this.headers, ...headers},
      );
}

class GetItemResponse {
  const GetItemResponse({required this.statusCode, this.item});
  final int statusCode;
  final Map<String, Object?>? item;
}

/// Raised by the stub to simulate a missing table — mirrors how a real AWS SDK
/// surfaces a modeled service error the interceptor records as a fault.
class ResourceNotFoundException implements Exception {
  const ResourceNotFoundException(this.message);
  final String message;
  @override
  String toString() => 'ResourceNotFoundException: $message';
}

/// Stub DynamoDB client that simulates a Smithy-generated client.
///
/// Real Smithy clients have an internal `httpSend` that this SDK intercepts
/// via the `rebuild` callback in [XRay.registerClient].
class StubDynamoDbClient {
  StubDynamoDbClient(
      {required this.region, SendFn<GetItemRequest, GetItemResponse>? httpSend})
      : _send = httpSend ?? _defaultSend;

  final String region;
  final SendFn<GetItemRequest, GetItemResponse> _send;

  Future<GetItemResponse> getItem(GetItemRequest request) => _send(request);

  /// Returns a copy with a different internal send function — mirrors the
  /// real Smithy client's `copyWith(httpSend: ...)` pattern.
  StubDynamoDbClient copyWith(
          {SendFn<GetItemRequest, GetItemResponse>? httpSend}) =>
      StubDynamoDbClient(region: region, httpSend: httpSend);

  static Future<GetItemResponse> _defaultSend(GetItemRequest req) async {
    await Future.delayed(const Duration(milliseconds: 20)); // simulate network
    // Prove the trace header reached the wire — a real client would send it.
    assert(req.headers.containsKey('X-Amzn-Trace-Id'),
        'interceptor should have injected the trace header');
    if (req.tableName == 'missing-table') {
      throw const ResourceNotFoundException('Requested table not found');
    }
    return GetItemResponse(
      statusCode: 200,
      item: {'id': req.key['id'], 'name': 'Alice'},
    );
  }
}

// ---------------------------------------------------------------------------

void main() async {
  // InMemorySender captures emitted segments so this example can print the
  // subsegment tracing produced. In production, swap it for UdpSender().
  final sender = InMemorySender();
  final tracer = XRayTracer(
    serviceName: 'ddb-demo',
    sender: sender,
    sampling: FixedRateSampler(1.0),
  );

  // ── Register once at cold start ───────────────────────────────────────────
  //
  // requestAdapter: given the raw request object, return a record with the
  //   tracing metadata the SDK needs.  withTraceHeader is called by the
  //   interceptor to inject X-Amzn-Trace-Id into the outbound request.
  //
  // responseAdapter: given the raw response, return statusCode plus optional
  //   contentLength, requestId, region, and AWS errorCode for the subsegment.
  //
  // rebuild: given the original client and a wrapSend function, extract the
  //   client's underlying send function, wrap it, and return a new client.
  //   This is the only place that touches client-internal types.
  XRay.registerClient<StubDynamoDbClient>(
    // namespace defaults to 'aws' for unrecognised client types
    namespace: 'aws',
    // Built-in extractors are keyed by real client type names (DynamoDbClient,
    // S3Client, …), so a custom/stub type needs an explicit extractor to pull
    // the resource (here the table) out of the request body into aws.* fields.
    // With the real DynamoDbClient this argument is unnecessary.
    extractor: (operation, body) => AwsData(
      operation: operation,
      tableName: body['TableName'] as String?,
    ),
    requestAdapter: (req) {
      final r = req as GetItemRequest;
      return (
        operationName: 'GetItem',
        method: 'POST',
        url: 'https://dynamodb.us-east-1.amazonaws.com',
        body: {'TableName': r.tableName},
        // withTraceHeader injects X-Amzn-Trace-Id into the outbound request and
        // returns the updated copy. With a real Smithy client this is:
        //   (original, header) => original.rebuild(
        //       headers: {...original.headers, 'X-Amzn-Trace-Id': header})
        withTraceHeader: (original, header) => (original as GetItemRequest)
            .withHeaders({'X-Amzn-Trace-Id': header}),
      );
    },
    responseAdapter: (res) {
      final r = res as GetItemResponse;
      return (
        statusCode: r.statusCode,
        contentLength: null,
        // requestId -> aws.request_id, the primary AWS support correlation key.
        // A real client reads this from the `x-amzn-RequestId` response header.
        requestId: 'STUB1234567890EXAMPLE',
        region: 'us-east-1',
        errorCode: null,
      );
    },
    rebuild: (original, wrapSend) {
      // Extract the internal send function, wrap it, and install the
      // wrapped version back into a new client instance.
      //
      // For the real Smithy DynamoDbClient this would be:
      //   final inner = (req) => original.rawSend(req as _RealRequest);
      //   return original.copyWith(httpSend: wrapSend(inner));
      final wrapped =
          wrapSend((req) => original.getItem(req as GetItemRequest));
      // wrapSend returns XRayHttpSendFn (Future<Object> Function(Object));
      // cast back to the concrete send type expected by copyWith.
      return original.copyWith(
        httpSend: (req) async => await wrapped(req) as GetItemResponse,
      );
    },
  );

  // ── Wrap and use ──────────────────────────────────────────────────────────
  final rawClient = StubDynamoDbClient(region: 'us-east-1');

  // fromClient returns a new instrumented client — every getItem() call now
  // opens a subsegment with operationName='GetItem', namespace='aws'.
  final ddb = XRay.fromClient(rawClient, tracer: tracer);

  await tracer.trace('ddb-demo', () async {
    print('Trace: ${tracer.currentTraceId}\n');

    // 1. A successful call — recorded as a clean subsegment.
    final response = await ddb.getItem(
      GetItemRequest(tableName: 'users', key: {'id': 'u-001'}),
    );
    print('getItem(users)  -> status=${response.statusCode} '
        'item=${response.item}');

    // 2. A failing call — the interceptor records fault=true plus the cause,
    //    then rethrows so your own error handling still runs.
    try {
      await ddb.getItem(
        GetItemRequest(tableName: 'missing-table', key: {'id': 'u-002'}),
      );
    } on ResourceNotFoundException catch (e) {
      print('getItem(missing-table) -> threw $e (recorded as a fault)');
    }
  });

  // The segment is now closed and captured by InMemorySender. Inspect the
  // subsegments tracing produced — this is what gets serialized to the daemon.
  _printSubsegments(sender.segments.single);
}

void _printSubsegments(Segment segment) {
  print('\nCaptured ${segment.subsegments.length} subsegment(s):');
  for (final sub in segment.subsegments) {
    final aws = sub.aws;
    final durationMs = sub.endTime == null
        ? null
        : ((sub.endTime! - sub.startTime) * 1000).toStringAsFixed(1);
    print('  • ${sub.name}  namespace=${sub.namespace}'
        '${sub.fault ? '  fault=true' : ''}');
    if (aws != null) {
      print('      operation=${aws.operation}  table=${aws.tableName}  '
          'region=${aws.region}  request_id=${aws.requestId}');
    }
    if (sub.http?.response != null) {
      print('      http.status=${sub.http!.response!.status}');
    }
    if (sub.cause != null) {
      print(
          '      cause=${sub.cause!.exceptions.map((e) => e.type).join(', ')}');
    }
    if (durationMs != null) print('      duration=${durationMs}ms');
  }
}
