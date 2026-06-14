import 'dart:io';
import 'http/xray_http_overrides.dart';
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
