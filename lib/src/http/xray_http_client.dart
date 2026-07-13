import 'dart:async';
import 'dart:convert' show Encoding;
import 'dart:io';
import '../models/http_data.dart';
import '../models/subsegment.dart';
import '../models/trace_header.dart';
import '../context/trace_suppression.dart';
import '../tracer.dart';
import '../aws/region.dart' show isAwsHost;

/// Wraps a `dart:io` [HttpClient] to trace every outbound HTTP request.
///
/// For each request:
/// - opens a subsegment named by the request host
/// - injects the `X-Amzn-Trace-Id` header
/// - records response status and closes the subsegment on completion
final class XRayHttpClient implements HttpClient {
  XRayHttpClient(this._inner, this._tracer);

  final HttpClient _inner;
  final XRayTracer _tracer;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final segment = _tracer.currentSegment;
    // Pass through untraced when there is no active trace, or when a
    // higher-level wrapper (XRayBaseClient / XRay.fromClient) is already
    // tracing this request and has suppressed the dart:io patch to avoid a
    // duplicate, bare host-named subsegment.
    if (segment == null || dartIoTracingSuppressed) {
      return _inner.openUrl(method, url);
    }

    final namespace = isAwsHost(url.host) ? 'aws' : 'remote';
    final sub = _tracer.beginSubsegment(url.host, namespace: namespace);

    try {
      final innerRequest = await _inner.openUrl(method, url);
      innerRequest.headers.add(
        'X-Amzn-Trace-Id',
        buildTraceHeader(
          traceId: segment.traceId.toString(),
          segmentId: sub.id,
          sampled: _tracer.isSampled,
        ),
      );
      // Intercept the response by wrapping close().
      return _TracedRequest(innerRequest, sub, _tracer, method, url);
    } catch (e) {
      // Connection failed (DNS, refused, timeout…) — record the attempt and
      // close the subsegment as faulted so it still appears in X-Ray traces.
      _tracer.failSubsegment(
        sub.withHttp(HttpData(
          request: HttpRequestData(method: method, url: url.toString()),
        )),
        e,
      );
      rethrow;
    }
  }

  // ---- Delegate all other HttpClient members to _inner ----

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool v) => _inner.autoUncompress = v;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) => _inner.connectionTimeout = v;

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration v) => _inner.idleTimeout = v;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _inner.maxConnectionsPerHost = v;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? v) => _inner.userAgent = v;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials creds) =>
      _inner.addCredentials(url, realm, creds);

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials creds,
  ) =>
      _inner.addProxyCredentials(host, port, realm, creds);

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) =>
      _inner.authenticate = f;

  @override
  set authenticateProxy(
    Future<bool> Function(
      String host,
      int port,
      String scheme,
      String? realm,
    )? f,
  ) =>
      _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? cb,
  ) =>
      _inner.badCertificateCallback = cb;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      openUrl(
          'DELETE', Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      openUrl('GET', Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      openUrl('HEAD', Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      openUrl('PATCH', Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      openUrl('POST', Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      openUrl('PUT', Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )? f,
  ) =>
      _inner.connectionFactory = f;

  @override
  set keyLog(Function(String line)? f) => _inner.keyLog = f;
}

/// Wraps [HttpClientRequest] to intercept [close] and record the response.
final class _TracedRequest implements HttpClientRequest {
  _TracedRequest(
    this._inner,
    this._sub,
    this._tracer,
    this._method,
    this._url,
  );

  final HttpClientRequest _inner;
  Subsegment _sub;
  final XRayTracer _tracer;
  final String _method;
  final Uri _url;

  @override
  Future<HttpClientResponse> close() async {
    try {
      final response = await _inner.close();

      _sub = _sub.withHttpCall(
        method: _method,
        url: _url.toString(),
        status: response.statusCode,
        traced: true,
      );

      // Register the enriched sub so that if the caller never drains the body
      // (HEAD, 204/304, status-only early return), the finalize-time sweep
      // emits this document — with its status — instead of a bare span.
      _tracer.updatePending(_sub);

      // Wrap the response stream so the subsegment is closed only after the
      // body is fully consumed. If the body stream errors (e.g. connection
      // reset mid-read), the subsegment is marked as faulted.
      return _TracedResponse(response, _sub, _tracer, _method, _url);
    } catch (e) {
      // Request was sent but the response could not be read (reset, timeout…).
      // Record what we know and mark the subsegment as faulted.
      _tracer.failSubsegment(
        _sub.withHttp(HttpData(
          request: HttpRequestData(
            method: _method,
            url: _url.toString(),
            traced: true,
          ),
        )),
        e,
      );
      rethrow;
    }
  }

  // Delegate everything else.
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  Future<HttpClientResponse> get done => _inner.done;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding e) => _inner.encoding = e;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? st]) => _inner.addError(error, st);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future<void> flush() => _inner.flush();
  @override
  void write(Object? obj) => _inner.write(obj);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? obj = '']) => _inner.writeln(obj);
  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool v) => _inner.bufferOutput = v;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int v) => _inner.contentLength = v;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool v) => _inner.followRedirects = v;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int v) => _inner.maxRedirects = v;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool v) => _inner.persistentConnection = v;
}

/// Wraps [HttpClientResponse] to defer the subsegment close until the response
/// body stream is fully consumed. If the stream errors, the subsegment is
/// marked as faulted instead of completing normally.
final class _TracedResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _TracedResponse(
    this._inner,
    this._sub,
    this._tracer,
    this._method,
    this._url,
  ) : _done = false {
    _stream = _inner.transform(StreamTransformer.fromHandlers(
      handleData: (data, sink) => sink.add(data),
      handleError: (e, st, sink) {
        // A stream consumed with cancelOnError: false (the default) can emit
        // an error *and then* done; guard so the subsegment is recorded once.
        if (!_done) {
          _done = true;
          _tracer.failSubsegment(_sub, e);
        }
        sink.addError(e, st);
      },
      handleDone: (sink) {
        if (!_done) {
          _done = true;
          _tracer.endSubsegment(_sub);
        }
        sink.close();
      },
    ));
  }

  final HttpClientResponse _inner;
  final Subsegment _sub;
  final XRayTracer _tracer;
  final String _method;
  final Uri _url;
  bool _done;
  late Stream<List<int>> _stream;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  // HttpClientResponse properties — delegated to _inner.
  @override
  int get statusCode => _inner.statusCode;
  @override
  String get reasonPhrase => _inner.reasonPhrase;
  @override
  int get contentLength => _inner.contentLength;
  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  bool get isRedirect => _inner.isRedirect;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  List<RedirectInfo> get redirects => _inner.redirects;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  X509Certificate? get certificate => _inner.certificate;
  @override
  Future<Socket> detachSocket() async {
    final socket = await _inner.detachSocket();
    if (!_done) {
      _tracer.endSubsegment(
        _sub.withHttpCall(
          method: _method,
          url: _url.toString(),
          status: _inner.statusCode,
          traced: true,
        ),
      );
      _done = true;
    }
    return socket;
  }

  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);
}
