import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/aws_data.dart';
import '../models/cause.dart';
import '../models/http_data.dart';
import '../trace_suppression.dart';
import '../tracer.dart';
import '../utils.dart' show awsDomainSuffix;
import '../wrappers/xray_interceptor.dart' show buildTraceHeader;

/// Wraps [http.Client] to trace every outbound HTTP request through
/// `package:http`.
///
/// Every request opens a subsegment, injects `X-Amzn-Trace-Id`, and records
/// the response status. The subsegment is closed only after the response body
/// stream is fully consumed — body-stream errors are captured and mark the
/// subsegment as faulted.
///
/// ## AWS calls
///
/// When the target host ends with `.amazonaws.com`, this client additionally:
///
///  * names the subsegment after the service (e.g. `dynamodb`, `sns`) rather
///    than the raw host,
///  * attaches an [AwsData] block (`operation`, plus `table_name` / `topic_arn`
///    / `queue_url` / `bucket_name` / `key_id` when present in the request),
///    parsed from the `X-Amz-Target` header (JSON protocols) or the `Action`
///    form field (query protocols), and
///  * on a non-2xx response, reads the AWS error body and records the AWS
///    exception `type` + `message` as the subsegment `cause`.
///
/// The error cause is read directly from the response because the agilord
/// `aws_*_api` protocols consume the whole body before throwing, so the thrown
/// exception never reaches this client's `catch`.
///
/// Requires `package:http` in your `pubspec.yaml`:
/// ```yaml
/// dependencies:
///   http: ^1.0.0
///   aws_xray_sdk: ^0.1.0
/// ```
///
/// Usage:
/// ```dart
/// final client = XRayBaseClient(http.Client(), tracer);
/// final response = await client.get(Uri.parse('https://api.example.com'));
/// ```
final class XRayBaseClient extends http.BaseClient {
  XRayBaseClient(this._inner, this._tracer);

  final http.Client _inner;
  final XRayTracer _tracer;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final segment = _tracer.currentSegment;
    if (segment == null) return _inner.send(request);

    final isAws = request.url.host.endsWith(awsDomainSuffix);
    final namespace = isAws ? 'aws' : 'remote';
    final subName = isAws ? _serviceName(request.url.host) : request.url.host;

    var sub = _tracer.beginSubsegment(subName, namespace: namespace);

    request.headers['X-Amzn-Trace-Id'] = buildTraceHeader(
      traceId: segment.traceId.toString(),
      segmentId: sub.id,
      sampled: _tracer.isSampled,
    );

    try {
      // Suppress the global dart:io patch for this send so the same request is
      // not traced twice (once here, once as a bare host-named subsegment by
      // an XRayHttpClient sitting under package:http's IOClient).
      final response =
          await runWithoutDartIoTracing(() => _inner.send(request));
      // Build the aws block from request + response so it carries the
      // request_id (response header), region, and resource_names.
      final awsData = isAws ? _awsDataFor(request, response: response) : null;
      sub = sub.withHttpCall(
        method: request.method,
        url: request.url.toString(),
        status: response.statusCode,
        contentLength: response.contentLength,
      );
      if (awsData != null) sub = sub.withAws(awsData);

      // On an AWS error response, buffer the body so we can extract the AWS
      // exception type/message into the subsegment cause. The body is then
      // re-emitted to the caller unchanged.
      final isError = response.statusCode < 200 || response.statusCode >= 300;
      if (isAws && isError) {
        final bytes = await response.stream.toBytes();
        final cause = _awsErrorCause(response, bytes);
        if (cause != null) sub = sub.withCause(cause);
        _tracer.endSubsegment(sub);
        return http.StreamedResponse(
          Stream.value(bytes),
          response.statusCode,
          contentLength: response.contentLength,
          headers: response.headers,
          reasonPhrase: response.reasonPhrase,
          request: response.request,
        );
      }

      var closed = false;
      final tracedSub = sub;
      final tracedStream = response.stream
          .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (data, sink) => sink.add(data),
        handleError: (e, st, sink) {
          if (!closed) {
            closed = true;
            _tracer.failSubsegment(tracedSub, e);
          }
          sink.addError(e, st);
        },
        handleDone: (sink) {
          if (!closed) {
            closed = true;
            _tracer.endSubsegment(tracedSub);
          }
          sink.close();
        },
      ));

      return http.StreamedResponse(
        tracedStream,
        response.statusCode,
        contentLength: response.contentLength,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
        request: response.request,
      );
    } catch (e) {
      // Transport failure (no response): record request-only aws data.
      final awsData = isAws ? _awsDataFor(request) : null;
      var failed = sub.withHttp(HttpData(
        request: HttpRequestData(
          method: request.method,
          url: request.url.toString(),
        ),
      ));
      if (awsData != null) failed = failed.withAws(awsData);
      _tracer.failSubsegment(failed, e);
      rethrow;
    }
  }

  /// Maps an AWS host to X-Ray's canonical service name so the console renders
  /// a single, properly-typed service node (e.g. **DynamoDB**, **SNS**) rather
  /// than a raw hostname.
  ///
  /// The endpoint prefix is the first label of the host
  /// (`dynamodb.us-east-1.amazonaws.com` → `dynamodb`); unknown prefixes fall
  /// back to the prefix as-is.
  static String _serviceName(String host) {
    final prefix = host.split('.').first.toLowerCase();
    return _canonicalServiceNames[prefix] ?? prefix;
  }

  /// AWS endpoint prefix → X-Ray canonical service name.
  static const Map<String, String> _canonicalServiceNames = {
    'dynamodb': 'DynamoDB',
    'sns': 'SNS',
    'sqs': 'SQS',
    's3': 'S3',
    'kms': 'KMS',
    'lambda': 'Lambda',
    'states': 'SFN',
    'secretsmanager': 'SecretsManager',
    'sts': 'STS',
    'kinesis': 'Kinesis',
    'firehose': 'Firehose',
    'ssm': 'SSM',
    'events': 'EventBridge',
    'logs': 'CloudWatchLogs',
    'monitoring': 'CloudWatch',
  };

  /// Builds [AwsData] for an AWS request: the operation name plus any
  /// resource identifier found in the request body.
  ///
  /// [response] (when available) supplies the `request_id` from the
  /// `x-amzn-RequestId` / `x-amz-request-id` header and the `region` parsed from
  /// the host, mirroring the AWS X-Ray SDK for Node.js `aws` block.
  static AwsData? _awsDataFor(
    http.BaseRequest request, {
    http.BaseResponse? response,
  }) {
    final operation = _operationName(request);
    if (operation == null) return null;

    final body = _bodyParams(request);
    final tableName = body['TableName'] as String?;
    final bucketName = body['Bucket'] as String?;
    final queueUrl = body['QueueUrl'] as String?;
    final topicArn = body['TopicArn'] as String?;
    final keyId = body['KeyId'] as String?;

    // resource_names: the named resources this call targets, so each appears as
    // its own node in the X-Ray service map (matches the Node.js SDK).
    final resourceNames = [
      for (final r in [tableName, bucketName, queueUrl, topicArn])
        if (r != null) r,
    ];

    return AwsData(
      operation: operation,
      region: _regionFromHost(request.url.host),
      requestId: response == null ? null : _requestId(response),
      tableName: tableName,
      bucketName: bucketName,
      keyId: keyId,
      queueUrl: queueUrl,
      topicArn: topicArn,
      resourceNames: resourceNames.isEmpty ? null : resourceNames,
    );
  }

  /// `dynamodb.us-east-1.amazonaws.com` → `us-east-1` (null for global hosts
  /// like `sts.amazonaws.com`).
  static String? _regionFromHost(String host) {
    final parts = host.split('.');
    // <service>.<region>.amazonaws.com  → 4 labels with a hyphenated region.
    if (parts.length == 4 && parts[1].contains('-')) return parts[1];
    return null;
  }

  /// The AWS request id from the response headers, if present.
  static String? _requestId(http.BaseResponse response) =>
      response.headers['x-amzn-requestid'] ??
      response.headers['x-amz-request-id'];

  /// Extracts the operation/action name from an AWS request.
  ///
  ///  * JSON protocols (DynamoDB, etc.) carry it in `X-Amz-Target`, e.g.
  ///    `DynamoDB_20120810.GetItem` → `GetItem`.
  ///  * Query protocols (SNS, SQS, …) carry it as the `Action` form field, e.g.
  ///    `Action=Publish` → `Publish`.
  static String? _operationName(http.BaseRequest request) {
    final target =
        request.headers['X-Amz-Target'] ?? request.headers['x-amz-target'];
    if (target != null && target.isNotEmpty) {
      return target.contains('.') ? target.split('.').last : target;
    }
    if (request is http.Request) {
      final action = Uri.splitQueryString(request.body)['Action'];
      if (action != null && action.isNotEmpty) return action;
    }
    return null;
  }

  /// Parses request-body parameters for resource extraction.
  ///
  /// JSON bodies are decoded as a map; query (`x-www-form-urlencoded`) bodies
  /// are split into key/value pairs (e.g. SNS `TopicArn=...`).
  static Map<String, Object?> _bodyParams(http.BaseRequest request) {
    if (request is! http.Request || request.body.isEmpty) return const {};
    final body = request.body.trimLeft();
    if (body.startsWith('{')) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, Object?>) return decoded;
      } catch (_) {/* fall through */}
      return const {};
    }
    try {
      return Uri.splitQueryString(request.body);
    } catch (_) {
      return const {};
    }
  }

  /// Reads an AWS error response body and builds a [Cause] carrying the AWS
  /// exception `type` and `message`.
  static Cause? _awsErrorCause(
      http.StreamedResponse response, List<int> bytes) {
    String type =
        response.headers['x-amzn-errortype']?.split(':').first ?? 'HttpError';
    String message = 'HTTP ${response.statusCode}';

    final text = utf8.decode(bytes, allowMalformed: true).trim();
    if (text.isNotEmpty) {
      if (text.startsWith('{')) {
        try {
          final json = jsonDecode(text) as Map<String, Object?>;
          final rawType = (json['__type'] ?? json['code']) as String?;
          if (rawType != null) type = rawType.split('#').last;
          message = (json['message'] ?? json['Message']) as String? ?? message;
        } catch (_) {/* keep header-derived type + status message */}
      } else if (text.contains('<')) {
        // Query-protocol XML error: <Error><Code>..</Code><Message>..</Message>
        type = _xmlTag(text, 'Code') ?? type;
        message = _xmlTag(text, 'Message') ?? message;
      }
    }

    // remote: true — the error came from a downstream service, per the X-Ray
    // schema and the Node.js SDK convention for AWS-SDK call failures.
    return Cause(exceptions: [
      XRayException(
        id: _exceptionId(),
        type: type,
        message: message,
        remote: true,
      ),
    ]);
  }

  static String? _xmlTag(String xml, String tag) {
    final match = RegExp('<$tag>(.*?)</$tag>', dotAll: true).firstMatch(xml);
    return match?.group(1)?.trim();
  }

  static String _exceptionId() => XRayException.from(Object()).id;
}
