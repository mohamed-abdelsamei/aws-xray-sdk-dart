import 'dart:io';
import 'http/xray_http_overrides.dart';
import 'tracer.dart';
import 'wrappers/aws_service_names.dart';
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
  /// [namespace] defaults to the value in [awsServiceNamespaces] for [T].
  /// [extractor] defaults to the built-in extractor for [T] if available.
  ///
  /// [requestAdapter] and [responseAdapter] extract tracing metadata from the
  /// client's type-erased request and response objects. Consumers cast to
  /// their concrete types internally.
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
    final resolvedNamespace =
        namespace ?? awsServiceNamespaces[T.toString()] ?? 'aws';
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
}
