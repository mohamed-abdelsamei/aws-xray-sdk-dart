import 'dart:io';

import 'package:http/http.dart' as http;

import 'http/xray_base_client.dart';
import 'http/xray_http_overrides.dart';
import 'lambda/lambda_trace_capture.dart';
import 'models/segment.dart';
import 'sampling/sampling_strategy.dart';
import 'tracer.dart';
import 'wrappers/client_registry.dart';
import 'wrappers/resource_extractor.dart';
import 'wrappers/xray_interceptor.dart';

/// Top-level facade for the X-Ray client.
///
/// Use [fromClient] to wrap a Smithy AWS SDK client and [patchHttp] to
/// automatically trace all `dart:io` HTTP calls.
abstract final class XRay {
  XRay._();

  /// The process-wide default [XRayTracer].
  ///
  /// Returns the tracer installed by [configure] or the [tracer] setter; if
  /// none has been installed, returns a shared **no-op** tracer that discards
  /// everything. This lets `XRay`-based instrumentation (e.g. the zero-arg
  /// `XRayBaseClient`) run unconditionally — when tracing is unconfigured it
  /// simply does nothing.
  static XRayTracer get tracer => defaultTracer;

  /// Installs [value] as the process-wide default tracer (see [tracer]).
  ///
  /// Set to null to clear it (the no-op resumes). Mainly for tests and for
  /// callers that build their own tracer instead of calling [configure].
  static set tracer(XRayTracer? value) => defaultTracer = value;

  /// Whether a real (non-no-op) tracer has been installed via [configure] or
  /// the [tracer] setter.
  static bool get isConfigured => isDefaultTracerConfigured;

  /// Adds indexed [annotations] to the span currently being traced, using the
  /// process-wide [tracer].
  ///
  /// A facade over `XRay.tracer.annotateAll(...)` so application code can add
  /// request-scoped annotations (request id, operation, environment, …) without
  /// importing or holding an [XRayTracer]. Annotations are searchable via X-Ray
  /// filter expressions; keys and values are sanitized per [XRayTracer.annotate].
  ///
  /// No-ops safely when there is no active trace, so it is always safe to call:
  /// ```dart
  /// XRay.annotate({'operationId': id, 'environment': env});
  /// ```
  static void annotate(Map<String, Object> annotations) =>
      defaultTracer.annotateAll(annotations);

  /// Adds non-indexed [value] under [key] to the span currently being traced,
  /// using the process-wide [tracer].
  ///
  /// A facade over `XRay.tracer.addMetadata(...)`. Metadata is not searchable
  /// but may be any JSON-serializable object. No-ops safely off-trace.
  static void metadata(String key, Object value,
          {String namespace = 'default'}) =>
      defaultTracer.addMetadata(key, value, namespace: namespace);

  /// One-call setup: builds a tracer, installs it as the process-wide default
  /// ([tracer]), and patches `dart:io` HTTP ([patchHttp]).
  ///
  /// **Idempotent** — calling it again is a no-op and returns the already-
  /// installed tracer, so it is safe to call from multiple entry points or
  /// repeatedly in tests (use [reset] to force re-configuration).
  ///
  /// When [fromEnv] is true (the default) the standard AWS environment is read:
  ///  * `AWS_XRAY_DAEMON_ADDRESS` → daemon `host:port` (IPv6-literal safe),
  ///    falling back to `127.0.0.1:2000`;
  ///  * `AWS_LAMBDA_FUNCTION_NAME` → default service name.
  ///
  /// Explicit [serviceName], [sampling], or a fully built [tracer] override the
  /// environment. Pass [patchDartIoHttp] = false to skip the global HTTP patch.
  static XRayTracer configure({
    XRayTracer? tracer,
    String? serviceName,
    SamplingStrategy? sampling,
    bool fromEnv = true,
    bool patchDartIoHttp = true,
  }) {
    final existing = _resolveInstalled();
    if (existing != null) return existing;

    final env = fromEnv ? Platform.environment : const <String, String>{};
    final (host, port) = _parseDaemonAddress(env['AWS_XRAY_DAEMON_ADDRESS']);
    final name =
        serviceName ?? env['AWS_LAMBDA_FUNCTION_NAME'] ?? 'dart-service';

    final built = tracer ??
        XRayTracer(
          serviceName: name,
          sampling: sampling,
          daemonHost: host,
          daemonPort: port,
        );

    defaultTracer = built;
    if (patchDartIoHttp) patchHttp(built);
    return built;
  }

  /// Clears the installed default tracer and removes the HTTP patch, returning
  /// to the unconfigured (no-op) state. Intended for tests.
  static void reset() {
    unpatchHttp();
    defaultTracer = null;
  }

  static XRayTracer? _resolveInstalled() =>
      isDefaultTracerConfigured ? defaultTracer : null;

  /// Splits an `AWS_XRAY_DAEMON_ADDRESS` value into `(host, port)`, defaulting
  /// to `127.0.0.1:2000`. Uses [String.lastIndexOf] for the port separator so
  /// IPv6 literals (which contain `:`) are handled correctly.
  static (String, int) _parseDaemonAddress(String? value) {
    const defaultHost = '127.0.0.1';
    const defaultPort = 2000;
    if (value == null || value.isEmpty) return (defaultHost, defaultPort);

    final sep = value.lastIndexOf(':');
    if (sep <= 0 || sep == value.length - 1) return (value, defaultPort);

    final host = value.substring(0, sep);
    final port = int.tryParse(value.substring(sep + 1));
    return (host, port ?? defaultPort);
  }

  /// Wraps [client] with X-Ray tracing and returns an instrumented copy.
  ///
  /// The client type [T] must have been registered via [registerClient]
  /// before calling this method.
  ///
  /// [fromClient] constructs an [XRayInterceptor] from the descriptor and
  /// passes its `wrap` function to the consumer-supplied `rebuild` callback.
  /// The consumer extracts their client's underlying send function, passes it
  /// through `wrapSend`, and installs the result back into a new client
  /// instance — without any knowledge of this class.
  ///
  /// Example:
  /// ```dart
  /// final ddb = XRay.fromClient(DynamoDbClient(...), tracer: tracer);
  /// ```
  static T fromClient<T extends Object>(T client,
      {required XRayTracer tracer}) {
    final descriptor = clientRegistry[T] as ClientDescriptor<T>?;
    if (descriptor == null) {
      throw StateError(
        'No XRay client descriptor registered for $T. '
        'Call XRay.registerClient<$T>(...) before using fromClient.',
      );
    }

    final interceptor = XRayInterceptor<Object, Object>(
      tracer: tracer,
      namespace: descriptor.namespace,
      extractor: descriptor.extractor,
      requestAdapter: descriptor.requestAdapter,
      responseAdapter: descriptor.responseAdapter,
    );

    return descriptor.rebuild(client, interceptor.wrap);
  }

  /// Registers a Smithy client type so [fromClient] can wrap it.
  ///
  /// [namespace] defaults to `aws`.
  /// [extractor] defaults to the built-in extractor for [T] if available.
  ///
  /// [requestAdapter] and [responseAdapter] extract tracing metadata from the
  /// client's type-erased request and response objects. Consumers cast to
  /// their concrete types internally. [responseAdapter] may return null for
  /// optional `contentLength`, `requestId`, `region`, and `errorCode` fields.
  ///
  /// [rebuild] receives the original client and a [XRayWrapFn]. It must
  /// extract the client's underlying send function, pass it through [wrapSend],
  /// and return a new client using the intercepted send.
  ///
  /// Call once at application startup, before any [fromClient] call:
  /// ```dart
  /// XRay.registerClient<DynamoDbClient>(
  ///   requestAdapter: (req) { final r = req as DdbReq; return (...); },
  ///   responseAdapter: (res) { final r = res as DdbRes; return (...); },
  ///   rebuild: (client, wrapSend) {
  ///     final inner = (req) => client.rawSend(req as DdbReq);
  ///     return client.copyWith(httpSend: wrapSend(inner));
  ///   },
  /// );
  /// ```
  static void registerClient<T extends Object>({
    String? namespace,
    ResourceExtractor? extractor,
    required SmithyRequestAdapter<Object> Function(Object) requestAdapter,
    required SmithyResponseAdapter<Object> Function(Object) responseAdapter,
    required T Function(T original, XRayWrapFn wrapSend) rebuild,
  }) {
    final resolvedNamespace = _traceNamespace(namespace ?? 'aws');
    final resolvedExtractor =
        extractor ?? builtInExtractors[T.toString()] ?? defaultExtractor;

    clientRegistry[T] = ClientDescriptor<T>(
      namespace: resolvedNamespace,
      extractor: resolvedExtractor,
      requestAdapter: requestAdapter,
      responseAdapter: responseAdapter,
      rebuild: rebuild,
    );
  }

  /// Patches `dart:io` globally so every [HttpClient] created from now on
  /// is wrapped with [XRayHttpClient].
  ///
  /// Chains any existing [HttpOverrides.global] so other patches are preserved.
  static void patchHttp(XRayTracer tracer) {
    HttpOverrides.global = XRayHttpOverrides(tracer, HttpOverrides.current);
  }

  /// Removes the X-Ray `dart:io` HTTP patch, restoring the previous overrides.
  static void unpatchHttp() {
    final current = HttpOverrides.current;
    if (current is XRayHttpOverrides) {
      HttpOverrides.global = current.previous;
    }
  }

  /// Wraps a `package:http` [http.Client] with X-Ray tracing.
  ///
  /// A convenience for `XRayBaseClient(inner, tracer)`. Use it as the
  /// underlying HTTP client for `package:http`-based AWS SDKs (e.g.
  /// `aws_client` / the agilord `aws_*_api` packages), which accept an
  /// `http.Client` — every request they make is then traced, with AWS-aware
  /// subsegment naming and resource extraction (operation, table/queue/bucket)
  /// for `*.amazonaws.com` hosts.
  ///
  /// ```dart
  /// // aws_*_api clients take a `client:` argument:
  /// final dynamoDB = DynamoDB(
  ///   region: 'us-east-1',
  ///   client: XRay.httpClientFor(tracer),
  /// );
  /// ```
  ///
  /// [inner] defaults to a fresh `http.Client()`. When [tracer] is null the
  /// process-wide [tracer] is resolved **per request**, so a client handed out
  /// before [configure] runs still traces afterward — order-independent. Pass an
  /// explicit [tracer] only to pin one. Tracing is gated on the active
  /// [XRayTracer.run] zone: outside one, requests pass through untraced.
  static http.Client httpClientFor(XRayTracer? tracer, {http.Client? inner}) =>
      XRayBaseClient(inner ?? http.Client(), tracer);

  /// Returns a pre-wrapped `http.Client` for AWS SDKs, using the process-wide
  /// default [tracer].
  ///
  /// Zero-config shorthand for `httpClientFor(null, inner: inner)` — hand it to
  /// any `aws_client` / `aws_*_api` client's `client:` argument so all its
  /// calls are traced once `XRay.configure` has run. The tracer is resolved per
  /// request, so this is safe to call before `configure` (e.g. in a field
  /// initializer or constructor):
  ///
  /// ```dart
  /// final ddb = DynamoDB(region: 'us-east-1', client: XRay.aws());
  /// ```
  static http.Client aws({http.Client? inner}) =>
      XRayBaseClient(inner ?? http.Client());

  /// Runs a single Lambda invocation [fn] correctly traced, using the trace
  /// context [capture] sniffed from the runtime's `Lambda-Runtime-Trace-Id`
  /// header.
  ///
  /// When the captured context carries a parent id, the work is parented under
  /// Lambda's auto-created `AWS::Lambda::Function` segment via
  /// [XRayTracer.runLambda]; otherwise (no header captured — e.g. local
  /// testing) a fresh top-level segment is started via [XRayTracer.run]. Uses
  /// the process-wide [tracer], so [configure] should run first.
  ///
  /// The runtime-specific handler glue (extracting [functionName] and the event)
  /// stays with the caller; this collapses the open/close/parent-decision into
  /// one call. Drive the runtime loop inside `capture.run(...)` so the header is
  /// captured:
  ///
  /// ```dart
  /// final capture = LambdaTraceCapture();
  /// await capture.run(() => invokeAwsLambdaRuntime([
  ///   FunctionHandler(name: 'h', action: (ctx, event) =>
  ///     XRay.runLambdaInvocation(capture, ctx.functionName,
  ///       // `() async =>` coerces a FutureOr-returning action to a Future.
  ///       () async => handle(ctx, event))),
  /// ]));
  /// ```
  static Future<T> runLambdaInvocation<T>(
    LambdaTraceCapture capture,
    String functionName,
    Future<T> Function() fn,
  ) {
    final tc = capture.context();
    if (tc.parentId != null) {
      return tracer.runLambda(
        tc.traceId,
        tc.parentId!,
        functionName,
        fn,
        sampled: tc.sampled,
      );
    }
    final segment = Segment.begin(
      name: functionName,
      traceId: tc.traceId,
      origin: 'AWS::Lambda::Function',
    );
    return tracer.run(segment, fn);
  }

  /// Creates an [HttpClient] that is **not** traced by [patchHttp].
  ///
  /// When [patchHttp] is active, every `HttpClient()` created anywhere is
  /// wrapped with `XRayHttpClient`.
  ///
  /// You usually do **not** need this to avoid double-tracing: `XRayBaseClient`
  /// and `XRay.fromClient` already suppress the global patch while they send,
  /// so wrapping a plain `http.Client()` with them yields exactly one
  /// subsegment even under `patchHttp`.
  ///
  /// Reach for this only when you want a client that emits **no** X-Ray
  /// subsegment at all while a global patch is active — for example a
  /// health-check or polling client whose requests should stay out of traces:
  ///
  /// ```dart
  /// final untraced = IOClient(XRay.untracedHttpClient());
  /// await untraced.get(healthCheckUri); // no subsegment, even under patchHttp
  /// ```
  ///
  /// The returned client comes from the overrides that were in place before the
  /// X-Ray patch (or the platform default if none), so it bypasses
  /// [XRayHttpOverrides] entirely.
  ///
  /// Note: a bare `HttpClient()` constructor always consults
  /// [HttpOverrides.current], and `HttpOverrides.runZoned(..., createHttpClient:
  /// null)` chains back to the previously-active override — so naively it would
  /// still be re-wrapped by an active patch. To get a genuinely unwrapped
  /// client, this supplies an explicit factory that builds the platform-default
  /// client (`_DefaultHttpOverrides().createHttpClient`), or delegates to the
  /// pre-patch override when one existed.
  static HttpClient untracedHttpClient([SecurityContext? context]) {
    final current = HttpOverrides.current;

    // A non-XRay override is in effect (e.g. the consumer's own): honour it.
    if (current != null && current is! XRayHttpOverrides) {
      return current.createHttpClient(context);
    }

    // An XRay patch (or no override). Build the client with an explicit factory
    // so it is never routed back through XRayHttpOverrides.
    final previous = current is XRayHttpOverrides ? current.previous : null;
    final factory = previous != null
        ? previous.createHttpClient
        : _DefaultHttpOverrides().createHttpClient;
    return HttpOverrides.runZoned(
      () => HttpClient(context: context),
      createHttpClient: factory,
    );
  }
}

String _traceNamespace(String namespace) {
  if (namespace == 'aws' || namespace == 'remote') return namespace;
  if (namespace.startsWith('AWS::')) return 'aws';
  return 'remote';
}

/// A base [HttpOverrides] whose `createHttpClient` returns the platform-default
/// `dart:io` client (via `super`), with no tracing wrapper.
final class _DefaultHttpOverrides extends HttpOverrides {}
