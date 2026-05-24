import 'dart:async';

import 'package:http/http.dart' as http;

import '../models/http_data.dart';
import '../tracer.dart';
import '../wrappers/xray_interceptor.dart' show buildTraceHeader;

const _awsDomainSuffix = '.amazonaws.com';

/// Wraps [http.Client] to trace every outbound HTTP request through
/// `package:http`.
///
/// Every request opens a subsegment, injects `X-Amzn-Trace-Id`, and records
/// the response status. The subsegment is closed only after the response body
/// stream is fully consumed — body-stream errors are captured and mark the
/// subsegment as faulted.
///
/// Requires `package:http` in your `pubspec.yaml`:
/// ```yaml
/// dependencies:
///   http: ^1.0.0
///   aws_xray_sdk: ^0.2.0
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

    final namespace =
        request.url.host.endsWith(_awsDomainSuffix) ? 'aws' : 'remote';
    var sub = _tracer.beginSubsegment(
      request.url.host,
      namespace: namespace,
    );

    sub = sub.withHttp(HttpData(
      request: HttpRequestData(
        method: request.method,
        url: request.url.toString(),
      ),
    ));

    request.headers['X-Amzn-Trace-Id'] = buildTraceHeader(
      traceId: segment.traceId.toString(),
      segmentId: sub.id,
      sampled: _tracer.isSampled,
    );

    try {
      final response = await _inner.send(request);
      sub = sub
          .withHttp(HttpData(
            request: HttpRequestData(
              method: request.method,
              url: request.url.toString(),
            ),
            response: HttpResponseData(status: response.statusCode),
          ))
          .applyStatus(response.statusCode);

      final tracedStream = response.stream
          .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (data, sink) => sink.add(data),
            handleError: (e, st, sink) {
              _tracer.failSubsegment(sub, e);
              sink.addError(e, st);
            },
            handleDone: (sink) {
              _tracer.endSubsegment(sub);
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
      _tracer.failSubsegment(sub, e);
      rethrow;
    }
  }
}
