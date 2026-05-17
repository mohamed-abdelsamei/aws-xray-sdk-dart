// Example: wrapping a Smithy-generated AWS SDK client with X-Ray tracing.
//
// XRay.registerClient<T>() teaches the SDK how to intercept requests for a
// specific client type.  XRay.fromClient<T>() then wraps any instance of that
// type so every call automatically opens a subsegment.
//
// This file uses a stub DynamoDbClient so it runs without a real Smithy
// dependency.  In your application, replace the stub with the real
// package:aws_dynamodb_api or Smithy-generated client.
//
// If you are using a community HTTP-based AWS client (e.g. aws_dynamodb_api
// from pub.dev) you don't need registerClient at all — just call
// XRay.patchHttp(tracer) once at startup and every request to *.amazonaws.com
// is automatically traced with namespace='aws'. See http_tracing.dart.

// ignore_for_file: unused_local_variable
import 'package:aws_xray_sdk/aws_xray_sdk.dart';

// ---------------------------------------------------------------------------
// Stub types — replace with the real Smithy client in your app.
// ---------------------------------------------------------------------------

typedef _SendFn<Req, Res> = Future<Res> Function(Req request);

class _GetItemRequest {
  const _GetItemRequest({required this.tableName, required this.key});
  final String tableName;
  final Map<String, Object?> key;
}

class _GetItemResponse {
  const _GetItemResponse({required this.statusCode, this.item});
  final int statusCode;
  final Map<String, Object?>? item;
}

/// Stub DynamoDB client that simulates a Smithy-generated client.
///
/// Real Smithy clients have an internal `httpSend` that this SDK intercepts
/// via the `rebuild` callback in [XRay.registerClient].
class StubDynamoDbClient {
  StubDynamoDbClient({required this.region, _SendFn<_GetItemRequest, _GetItemResponse>? httpSend})
      : _send = httpSend ?? _defaultSend;

  final String region;
  final _SendFn<_GetItemRequest, _GetItemResponse> _send;

  Future<_GetItemResponse> getItem(_GetItemRequest request) => _send(request);

  /// Returns a copy with a different internal send function — mirrors the
  /// real Smithy client's `copyWith(httpSend: ...)` pattern.
  StubDynamoDbClient copyWith({_SendFn<_GetItemRequest, _GetItemResponse>? httpSend}) =>
      StubDynamoDbClient(region: region, httpSend: httpSend);

  static Future<_GetItemResponse> _defaultSend(_GetItemRequest req) async {
    await Future.delayed(const Duration(milliseconds: 20)); // simulate network
    return _GetItemResponse(
      statusCode: 200,
      item: {'id': req.key['id'], 'name': 'Alice'},
    );
  }
}

// ---------------------------------------------------------------------------

void main() async {
  final tracer = XRayTracer(
    serviceName: 'ddb-demo',
    sender: NoopSender(), // swap for UdpSender() in production
    sampling: FixedRateSampler(1.0),
  );

  // ── Register once at cold start ───────────────────────────────────────────
  //
  // requestAdapter: given the raw request object, return a record with the
  //   tracing metadata the SDK needs.  withTraceHeader is called by the
  //   interceptor to inject X-Amzn-Trace-Id into the outbound request.
  //
  // responseAdapter: given the raw response, return statusCode and (optional)
  //   contentLength for the HTTP subsegment.
  //
  // rebuild: given the original client and a wrapSend function, extract the
  //   client's underlying send function, wrap it, and return a new client.
  //   This is the only place that touches client-internal types.
  XRay.registerClient<StubDynamoDbClient>(
    // namespace defaults to 'aws' for unrecognised client types
    namespace: 'aws',
    requestAdapter: (req) {
      final r = req as _GetItemRequest;
      return (
        operationName: 'GetItem',
        method: 'POST',
        url: 'https://dynamodb.us-east-1.amazonaws.com',
        body: {'TableName': r.tableName},
        // withTraceHeader injects the X-Amzn-Trace-Id into the request.
        // With real Smithy clients: return r.rebuild(headers: {..., 'X-Amzn-Trace-Id': h})
        withTraceHeader: (original, header) => original, // stub: header ignored
      );
    },
    responseAdapter: (res) {
      final r = res as _GetItemResponse;
      return (statusCode: r.statusCode, contentLength: null);
    },
    rebuild: (original, wrapSend) {
      // Extract the internal send function, wrap it, and install the
      // wrapped version back into a new client instance.
      //
      // For the real Smithy DynamoDbClient this would be:
      //   final inner = (req) => original.rawSend(req as _RealRequest);
      //   return original.copyWith(httpSend: wrapSend(inner));
      final inner = (req) => original.getItem(req as _GetItemRequest);
      final wrapped = wrapSend(inner);
      return original.copyWith(
        httpSend: wrapped,
      );
    },
  );

  // ── Wrap and use ──────────────────────────────────────────────────────────
  final rawClient = StubDynamoDbClient(region: 'us-east-1');

  // fromClient returns a new instrumented client — every getItem() call now
  // opens a subsegment with operationName='GetItem', namespace='aws'.
  final ddb = XRay.fromClient(rawClient, tracer: tracer);

  final segment = Segment.begin(
    name: 'ddb-demo',
    traceId: TraceId.generate(),
  );

  await tracer.run(segment, () async {
    print('Trace: ${segment.traceId}');

    final response = await ddb.getItem(
      _GetItemRequest(tableName: 'users', key: {'id': 'u-001'}),
    );
    print('GetItem status=${response.statusCode} item=${response.item}');
  });

  print('Segment with DynamoDB subsegment sent to X-Ray daemon');
}
