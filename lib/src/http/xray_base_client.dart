import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../aws/region.dart';
import '../aws/throttle_codes.dart';
import '../models/aws_data.dart';
import '../models/cause.dart';
import '../models/http_data.dart';
import '../models/trace_header.dart';
import '../context/trace_suppression.dart';
import '../tracer.dart';
import '../utils.dart';

/// Wraps [http.Client] to trace every outbound HTTP request through
/// `package:http`.
///
/// Every request opens a subsegment, injects `X-Amzn-Trace-Id`, records
/// `http.request.traced = true`, and records the response status. The subsegment
/// is closed after the response body stream is fully consumed. If the caller
/// never consumes the body, trace finalization emits it once with
/// `metadata.xray.incomplete = true`; body-stream errors are captured and mark
/// the subsegment as faulted.
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
///  * on a non-2xx response, reads the AWS error body, records the AWS exception
///    `type` + `message` as the subsegment `cause`, and marks known AWS
///    throttling error codes as throttled even when the status is not `429`.
///
/// The error cause is read directly from the response because the agilord
/// `aws_*_api` protocols consume the whole body before throwing, so the thrown
/// exception never reaches this client's `catch`.
///
/// The request object is mutated to inject `X-Amzn-Trace-Id`; treat
/// `package:http` request instances as single-use.
///
/// Requires `package:http` in your `pubspec.yaml`:
/// ```yaml
/// dependencies:
///   http: ^1.0.0
///   aws_xray_sdk: ^0.4.0
/// ```
///
/// Usage:
/// ```dart
/// final client = XRayBaseClient(http.Client(), tracer);
/// final response = await client.get(Uri.parse('https://api.example.com'));
/// ```
final class XRayBaseClient extends http.BaseClient {
  /// Wraps [inner]. When [tracer] is omitted the process-wide [defaultTracer]
  /// is resolved **per request** (a no-op until `XRay.configure` / `XRay.tracer`
  /// installs one), so a client built *before* tracing is configured still
  /// traces once it is. Pass an explicit [tracer] only to pin a specific one.
  XRayBaseClient(this._inner, [XRayTracer? tracer]) : _pinnedTracer = tracer;

  final http.Client _inner;

  /// The tracer pinned at construction, or null to resolve [defaultTracer]
  /// fresh on every [send].
  final XRayTracer? _pinnedTracer;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final tracer = _pinnedTracer ?? defaultTracer;
    final segment = tracer.currentSegment;
    if (segment == null) return _inner.send(request);

    final isAws = isAwsHost(request.url.host);
    final namespace = isAws ? 'aws' : 'remote';
    final subName = isAws ? _serviceName(request.url.host) : request.url.host;

    var sub = tracer.beginSubsegment(subName, namespace: namespace);

    request.headers['X-Amzn-Trace-Id'] = buildTraceHeader(
      traceId: segment.traceId.toString(),
      segmentId: sub.id,
      sampled: tracer.isSampled,
    );

    // Only the inner send sits in the rethrowing try: post-response
    // enrichment is guarded separately, so tracing never turns a successful
    // response into an exception.
    final http.StreamedResponse response;
    try {
      // Suppress the global dart:io patch for this send so the same request is
      // not traced twice (once here, once as a bare host-named subsegment by
      // an XRayHttpClient sitting under package:http's IOClient).
      response = await runWithoutDartIoTracing(() => _inner.send(request));
    } catch (e) {
      try {
        // Transport failure (no response): record request-only aws data.
        final awsData = isAws ? _awsDataFor(request) : null;
        var failed = sub.withHttp(HttpData(
          request: HttpRequestData(
            method: request.method,
            url: request.url.toString(),
            traced: true,
          ),
        ));
        if (awsData != null) failed = failed.withAws(awsData);
        tracer.failSubsegment(failed, e);
      } catch (_) {
        _quietly(() => tracer.endSubsegment(sub.withFault()));
      }
      rethrow;
    }

    // Status first, aws data second, each guarded on its own: a request whose
    // aws data cannot be built still records its http block and fault.
    try {
      sub = sub.withHttpCall(
        method: request.method,
        url: request.url.toString(),
        status: response.statusCode,
        contentLength: response.contentLength,
        traced: true,
      );
    } catch (_) {/* keep the bare subsegment */}
    if (isAws) {
      try {
        // Build the aws block from request + response so it carries the
        // request_id (response header), region, and resource_names.
        final awsData = _awsDataFor(request, response: response);
        if (awsData != null) sub = sub.withAws(awsData);
      } catch (_) {/* keep the http-only subsegment */}
    }

    // On an AWS error response, buffer the body so we can extract the AWS
    // exception type/message into the subsegment cause. The body is then
    // re-emitted to the caller unchanged.
    final isError = response.statusCode < 200 || response.statusCode >= 300;
    if (isAws && isError) {
      final List<int> bytes;
      try {
        bytes = await response.stream.toBytes();
      } catch (e) {
        // The body stream's own error: the caller would see it reading the
        // body, so surface it unchanged.
        _quietly(() => tracer.failSubsegment(sub, e));
        rethrow;
      }
      try {
        final error = _awsError(response, bytes);
        if (error != null) {
          var withCause = sub.withCause(error.cause);
          if (isThrottleErrorCode(error.type)) {
            withCause = withCause.withThrottle();
          }
          sub = withCause;
        }
      } catch (_) {/* close without the AWS cause */}
      final errorSub = sub;
      _quietly(() => tracer.endSubsegment(errorSub));
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        contentLength: response.contentLength,
        headers: response.headers,
        reasonPhrase: response.reasonPhrase,
        request: response.request,
      );
    }

    // Register the enriched sub so that if the caller never drains the body
    // (HEAD, 204/304, status-only early return), the finalize-time sweep
    // emits this document — with status/aws data — instead of a bare span.
    final tracedSub = sub;
    _quietly(() => tracer.updatePending(tracedSub));

    var closed = false;
    final tracedStream = response.stream
        .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (data, sink) => sink.add(data),
      handleError: (e, st, sink) {
        if (!closed) {
          closed = true;
          _quietly(() => tracer.failSubsegment(tracedSub, e));
        }
        sink.addError(e, st);
      },
      handleDone: (sink) {
        if (!closed) {
          closed = true;
          _quietly(() => tracer.endSubsegment(tracedSub));
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
  }

  /// Runs a tracer call whose failure must never reach the caller.
  static void _quietly(void Function() f) {
    try {
      f();
    } catch (_) {}
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
    // `is String` checks: a field of the wrong JSON type is skipped, never a
    // TypeError.
    final tableName = _string(body['TableName']);
    final bucketName = _string(body['Bucket']);
    final queueUrl = _string(body['QueueUrl']);
    final topicArn = _string(body['TopicArn']);
    final keyId = _string(body['KeyId']);
    // Lambda Invoke carries the target function in the URL path, not the body.
    final functionName = _lambdaFunctionName(request.url);

    // resource_names: the named resources this call targets, so each appears as
    // its own node in the X-Ray service map (matches the Node.js SDK).
    final resourceNames = [
      for (final r in [tableName, bucketName, queueUrl, topicArn, functionName])
        if (r != null) r,
    ];

    return AwsData(
      operation: operation,
      region: regionFromAwsHost(request.url.host),
      requestId: response == null ? null : _requestId(response),
      tableName: tableName,
      bucketName: bucketName,
      keyId: keyId,
      queueUrl: queueUrl,
      topicArn: topicArn,
      functionName: functionName,
      resourceNames: resourceNames.isEmpty ? null : resourceNames,
    );
  }

  static String? _string(Object? value) => value is String ? value : null;

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
  ///  * REST-JSON protocols (Lambda, …) carry it in the URL path, e.g.
  ///    `POST /2015-03-31/functions/{name}/invocations` → `Invoke`.
  static String? _operationName(http.BaseRequest request) {
    final target =
        request.headers['X-Amz-Target'] ?? request.headers['x-amz-target'];
    if (target != null && target.isNotEmpty) {
      return target.contains('.') ? target.split('.').last : target;
    }
    final body = _bodyText(request);
    if (body != null) {
      final action = Uri.splitQueryString(body)['Action'];
      if (action != null && action.isNotEmpty) return action;
    }
    return _restOperation(request.url);
  }

  /// Operation name for REST-protocol AWS endpoints whose action lives in the
  /// URL path rather than a header or body field. Currently covers the Lambda
  /// data-plane `Invoke` call; returns null for unrecognised paths.
  static String? _restOperation(Uri url) {
    if (url.host.split('.').first.toLowerCase() != 'lambda') return null;
    final segments = url.pathSegments;
    if (segments.length >= 3 &&
        segments[segments.length - 3] == 'functions' &&
        segments.last == 'invocations') {
      return 'Invoke';
    }
    return null;
  }

  /// The Lambda function name from an `Invoke` path
  /// (`/2015-03-31/functions/{name}/invocations`), or null.
  static String? _lambdaFunctionName(Uri url) {
    if (url.host.split('.').first.toLowerCase() != 'lambda') return null;
    final segments = url.pathSegments;
    if (segments.length >= 3 &&
        segments[segments.length - 3] == 'functions' &&
        segments.last == 'invocations') {
      return segments[segments.length - 2];
    }
    return null;
  }

  /// The request body as text, or null when it is not an [http.Request] or its
  /// bytes do not decode in the request's encoding (e.g. a binary S3 PUT).
  static String? _bodyText(http.BaseRequest request) {
    if (request is! http.Request) return null;
    try {
      return request.body;
    } catch (_) {
      return null;
    }
  }

  /// Parses request-body parameters for resource extraction.
  ///
  /// JSON bodies are decoded as a map; query (`x-www-form-urlencoded`) bodies
  /// are split into key/value pairs (e.g. SNS `TopicArn=...`).
  static Map<String, Object?> _bodyParams(http.BaseRequest request) {
    final text = _bodyText(request);
    if (text == null || text.isEmpty) return const {};
    final body = text.trimLeft();
    if (body.startsWith('{')) {
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, Object?>) return decoded;
      } catch (_) {/* fall through */}
      return const {};
    }
    try {
      return Uri.splitQueryString(text);
    } catch (_) {
      return const {};
    }
  }

  /// Reads an AWS error response body and builds a cause carrying the AWS
  /// exception `type` and `message`.
  static ({String type, Cause cause})? _awsError(
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
    return (
      type: type,
      cause: Cause(exceptions: [
        XRayException(
          id: _exceptionId(),
          type: type,
          message: truncateMessage(message),
          remote: true,
        ),
      ]),
    );
  }

  /// Extracts the first XML tag body from AWS query-protocol errors.
  static String? _xmlTag(String xml, String tag) {
    final open = RegExp(
      '<(?:\\w+:)?$tag(?:\\s[^>]*)?>',
      caseSensitive: false,
    );
    final m = open.firstMatch(xml);
    if (m == null) return null;

    final close = RegExp('</(?:\\w+:)?$tag\\s*>', caseSensitive: false);
    final cm = close.firstMatch(xml.substring(m.end));
    if (cm == null) return null;

    var inner = xml.substring(m.end, m.end + cm.start);
    inner = _unwrapCdata(inner);
    inner = _decodeXmlEntities(inner).trim();
    return inner.isEmpty ? null : inner;
  }

  /// Replaces CDATA sections with their literal contents.
  static String _unwrapCdata(String s) {
    if (!s.contains('<![CDATA[')) return s;
    return s.replaceAllMapped(
      RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true),
      (m) => m.group(1) ?? '',
    );
  }

  /// Decodes the five predefined XML entities plus numeric character refs.
  static String _decodeXmlEntities(String s) {
    if (!s.contains('&')) return s;
    return s.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|\w+);'), (m) {
      final e = m.group(1)!;
      switch (e) {
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'amp':
          return '&';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      if (e.startsWith('#')) {
        final isHex = e.startsWith('#x') || e.startsWith('#X');
        final digits = e.substring(isHex ? 2 : 1);
        final code = int.tryParse(digits, radix: isHex ? 16 : 10);
        if (code != null && code >= 0 && code <= 0x10FFFF) {
          return String.fromCharCode(code);
        }
      }
      return m.group(0)!; // unknown or out-of-range entity: leave as-is
    });
  }

  static String _exceptionId() => XRayException.from(Object()).id;
}
