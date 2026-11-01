import '../models/aws_data.dart';
import '../models/cause.dart';
import '../models/http_data.dart';
import '../models/subsegment.dart';
import '../aws/region.dart';
import '../aws/throttle_codes.dart';
import '../models/trace_header.dart';
import '../context/trace_suppression.dart';
import '../tracer.dart';
import 'resource_extractor.dart';

/// Intercepts a Smithy HTTP send call to open/close an X-Ray subsegment.
///
/// Usage: wrap the client's HTTP send function with [XRayInterceptor.wrap].
///
/// This class is intentionally decoupled from the Smithy types so it can be
/// tested without an aws_sdk_dart dependency. The [SendFn] typedef abstracts
/// the underlying transport.
typedef SendFn<Req, Res> = Future<Res> Function(Req request);

/// Extracts tracing metadata from a typed Smithy request.
typedef SmithyRequestAdapter<Req> = ({
  String operationName,
  String method,
  String url,
  Map<String, Object?> body,
  Req Function(Req original, String traceHeader) withTraceHeader,
});

/// Extracts response metadata from a typed Smithy response.
///
/// [requestId] becomes `aws.request_id`, [region] becomes `aws.region`, and
/// [errorCode] is used to identify AWS throttles that are returned with a
/// non-429 HTTP status.
typedef SmithyResponseAdapter<Res> = ({
  int statusCode,
  int? contentLength,
  String? requestId,
  String? region,
  String? errorCode,
});

/// Wraps a Smithy [SendFn] with X-Ray tracing.
final class XRayInterceptor<Req, Res> {
  const XRayInterceptor({
    required XRayTracer tracer,
    required String namespace,
    required ResourceExtractor extractor,
    required SmithyRequestAdapter<Req> Function(Req) requestAdapter,
    required SmithyResponseAdapter<Res> Function(Res) responseAdapter,
    int? Function(Object error)? errorStatus,
  })  : _tracer = tracer,
        _namespace = namespace,
        _extractor = extractor,
        _requestAdapter = requestAdapter,
        _responseAdapter = responseAdapter,
        _errorStatus = errorStatus;

  final XRayTracer _tracer;
  final String _namespace;
  final ResourceExtractor _extractor;
  final SmithyRequestAdapter<Req> Function(Req) _requestAdapter;
  final SmithyResponseAdapter<Res> Function(Res) _responseAdapter;

  /// Optional: maps an error thrown by the wrapped send to its HTTP status.
  ///
  /// Smithy clients throw on 4xx as well as 5xx. When this returns a status
  /// of 400 or above, the subsegment is classified like a response with that
  /// status (4xx error, 429 throttle, 5xx fault) and records
  /// `http.response.status`. A null or sub-400 result, or a throw, keeps the
  /// default: fault, or throttle when the error matches a throttle code.
  final int? Function(Object error)? _errorStatus;

  /// Returns a new send function that wraps [inner] with tracing.
  ///
  /// Tracing never faults the call: if a user adapter or subsegment enrichment
  /// throws, the request is still sent and its response (or [inner]'s own
  /// error, unchanged) is what the caller sees.
  SendFn<Req, Res> wrap(SendFn<Req, Res> inner) => (request) async {
        final segment = _tracer.currentSegment;
        if (segment == null) return inner(request);

        final SmithyRequestAdapter<Req> adapted;
        try {
          adapted = _requestAdapter(request);
        } catch (_) {
          // No operation name to trace under: send untraced.
          return inner(request);
        }
        var sub = _tracer.beginSubsegment(
          adapted.operationName,
          namespace: _namespace,
        );

        // Inject trace header using the sampling decision stored in the zone.
        // If injection fails, send the original request (still traced).
        Req tracedRequest;
        try {
          final traceHeader = buildTraceHeader(
            traceId: segment.traceId.toString(),
            segmentId: sub.id,
            sampled: _tracer.isSampled,
          );
          tracedRequest = adapted.withTraceHeader(request, traceHeader);
        } catch (_) {
          tracedRequest = request;
        }

        AwsData awsData;
        try {
          awsData = _extractor(adapted.operationName, adapted.body);
        } catch (_) {
          awsData = AwsData(operation: adapted.operationName);
        }

        final requestOnly = HttpData(
          request: HttpRequestData(
            method: adapted.method,
            url: adapted.url,
            traced: true,
          ),
        );

        final Res response;
        try {
          // Suppress the global dart:io patch for the inner send so a patched
          // HttpClient underneath the Smithy transport does not trace this same
          // request again as a bare host-named subsegment.
          response = await runWithoutDartIoTracing(() => inner(tracedRequest));
        } catch (e) {
          try {
            // Guarded: a throwing toString()/runtimeType must not drop the
            // status, throttle flag, or cause.
            final ex = XRayException.from(e);
            final status = _statusOf(e);
            final isThrottle =
                isThrottleErrorCode(ex.type) || isThrottleErrorCode(ex.message);
            final failed = sub.withHttp(requestOnly).withAws(awsData);
            if (status != null) {
              var classified = failed
                  .withHttp(HttpData(
                    request: requestOnly.request,
                    response: HttpResponseData(status: status),
                  ))
                  .applyStatus(status);
              if (isThrottle) classified = classified.withThrottle();
              _tracer
                  .endSubsegment(classified.withCause(Cause(exceptions: [ex])));
            } else if (isThrottle) {
              _tracer.endSubsegment(
                  failed.withThrottle().withCause(Cause(exceptions: [ex])));
            } else {
              _tracer.failSubsegment(failed, e);
            }
          } catch (_) {
            _endQuietly(sub.withFault());
          }
          rethrow;
        }

        try {
          final resAdapted = _responseAdapter(response);
          var done = sub
              .withHttpCall(
                method: adapted.method,
                url: adapted.url,
                status: resAdapted.statusCode,
                contentLength: resAdapted.contentLength,
                traced: true,
              )
              .withAws(AwsData(
                operation: awsData.operation,
                region: resAdapted.region ?? regionFromAwsUrl(adapted.url),
                requestId: resAdapted.requestId,
                tableName: awsData.tableName,
                bucketName: awsData.bucketName,
                keyId: awsData.keyId,
                queueUrl: awsData.queueUrl,
                topicArn: awsData.topicArn,
                resourceNames: awsData.resourceNames,
              ));
          if (resAdapted.errorCode != null &&
              isThrottleErrorCode(resAdapted.errorCode!)) {
            done = done.withThrottle();
          }
          _tracer.endSubsegment(done);
        } catch (_) {
          // Close without response data rather than fault a successful call.
          try {
            _tracer.endSubsegment(sub.withHttp(requestOnly).withAws(awsData));
          } catch (_) {
            _endQuietly(sub);
          }
        }
        return response;
      };

  /// The status [_errorStatus] reports for [error], or null when there is no
  /// hook, it throws, or it returns a non-error (< 400) status.
  int? _statusOf(Object error) {
    final hook = _errorStatus;
    if (hook == null) return null;
    try {
      final status = hook(error);
      return status != null && status >= 400 ? status : null;
    } catch (_) {
      return null;
    }
  }

  /// Last-resort close of the bare [sub] so it is never left pending.
  void _endQuietly(Subsegment sub) {
    try {
      _tracer.endSubsegment(sub);
    } catch (_) {}
  }
}
