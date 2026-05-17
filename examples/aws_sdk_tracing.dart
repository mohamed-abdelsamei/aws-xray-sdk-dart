// ignore_for_file: unused_local_variable
//
// This example shows how to register and wrap a Smithy-generated AWS SDK
// client (e.g. DynamoDbClient from package:aws_sdk_dart) with X-Ray tracing.
//
// It uses a stub DynamoDbClient to avoid a real aws_sdk_dart dependency in
// this example package. Replace the stub with the real Smithy client in your
// application.

import 'package:aws_xray_sdk/aws_xray_sdk.dart';

// ---------------------------------------------------------------------------
// Stub types — replace with the real Smithy client in your app.
// ---------------------------------------------------------------------------
class DynamoDbClient {
  DynamoDbClient({required String region});
  Future<Map<String, Object?>> getItem(Map<String, Object?> request) async =>
      {'item': null};
}
// ---------------------------------------------------------------------------

void main() async {
  final tracer = XRayTracer(
    serviceName: 'ddb-demo-service',
    sender: NoopSender(),
    sampling: FixedRateSampler(1.0),
  );

  // Register DynamoDbClient once at startup.
  // The `rebuild` closure tells the SDK how to inject a wrapped HTTP client
  // into a new client instance.  With the real Smithy client, replace the
  // stub rebuild with one that calls DynamoDbClient.copyWith(httpClient: ...).
  XRay.registerClient<DynamoDbClient>(
    namespace: 'AWS::DynamoDB',
    // requestAdapter and responseAdapter are type-erased: cast to your real
    // Smithy request/response types in production code.
    requestAdapter: (req) => (
      operationName: 'UnknownOperation',
      method: 'POST',
      url: 'https://dynamodb.us-east-1.amazonaws.com',
      body: const {},
      withTraceHeader: (r, h) => r, // stub: real clients set the header here
    ),
    responseAdapter: (res) => (statusCode: 200, contentLength: null),
    rebuild: (original, wrapSend) {
      // Real apps: extract inner send, wrap it, and return a new client.
      //   final inner = (req) => original.rawSend(req);
      //   return original.copyWith(httpSend: wrapSend(inner));
      return original; // stub — no Smithy HTTP layer to inject
    },
  );

  // Wrap the client — from this point every call is automatically traced.
  final rawClient = DynamoDbClient(region: 'us-east-1');
  final ddb = XRay.fromClient(rawClient, tracer: tracer);

  final segment = Segment.begin(
    name: 'dynamodb-operation',
    traceId: TraceId.generate(),
  );

  await tracer.run(segment, () async {
    print('Making DynamoDB request — trace: ${segment.traceId}');

    final response = await ddb.getItem({
      'TableName': 'my-table',
      'Key': {'id': 'test-key-123'},
    });

    print('Item found: ${response['item'] != null}');
  });

  print('Segment with DynamoDB subsegments sent to X-Ray daemon');
}
