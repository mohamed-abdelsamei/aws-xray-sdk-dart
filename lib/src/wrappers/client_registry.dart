import 'aws_service_names.dart';
import 'resource_extractor.dart';
import 'xray_interceptor.dart' show SmithyRequestAdapter, SmithyResponseAdapter;

/// A send function that wraps the underlying Smithy HTTP layer.
typedef XRayHttpSendFn = Future<Object> Function(Object request);

/// A function that wraps an inner Smithy HTTP send with X-Ray tracing.
///
/// The consumer's [ClientDescriptor.rebuild] receives this as its second
/// argument. It must:
///   1. Extract the original send function from the client.
///   2. Pass it to [XRayWrapFn] to get the intercepted version.
///   3. Return a new client instance using the intercepted send.
typedef XRayWrapFn = XRayHttpSendFn Function(XRayHttpSendFn inner);

/// Describes how to wrap a specific Smithy client type with X-Ray tracing.
///
/// [T] is the concrete client type (e.g. `DynamoDbClient`).
///
/// Register instances via [XRay.registerClient] at application startup.
final class ClientDescriptor<T extends Object> {
  const ClientDescriptor({
    required this.namespace,
    required this.extractor,
    required this.requestAdapter,
    required this.responseAdapter,
    required this.rebuild,
  });

  /// X-Ray namespace string, e.g. `'dynamodb'`, `'s3'`.
  final String namespace;

  /// Extracts [AwsData] from a serialized Smithy request body.
  final ResourceExtractor extractor;

  /// Extracts tracing metadata from a type-erased Smithy request object.
  ///
  /// Consumers cast to the actual request type internally:
  /// ```dart
  /// requestAdapter: (req) {
  ///   final typed = req as DynamoDbRequest;
  ///   return (operationName: typed.operationName, ...);
  /// }
  /// ```
  final SmithyRequestAdapter<Object> Function(Object) requestAdapter;

  /// Extracts HTTP status from a type-erased Smithy response object.
  ///
  /// Consumers cast to the actual response type internally:
  /// ```dart
  /// responseAdapter: (res) => (statusCode: (res as DynamoDbResponse).statusCode, contentLength: null),
  /// ```
  final SmithyResponseAdapter<Object> Function(Object) responseAdapter;

  /// Returns a new [T] with X-Ray tracing installed.
  ///
  /// [wrapSend] is the interceptor's `wrap` function. The consumer must:
  ///   1. Extract the original send function from [original].
  ///   2. Pass it to [wrapSend] to obtain the intercepted send.
  ///   3. Return a new [T] that routes HTTP through the intercepted send.
  ///
  /// Example:
  /// ```dart
  /// rebuild: (client, wrapSend) {
  ///   final inner = (req) => client.rawSend(req as TypedReq);
  ///   final wrapped = wrapSend(inner);
  ///   return client.copyWith(httpSend: wrapped);
  /// }
  /// ```
  final T Function(T original, XRayWrapFn wrapSend) rebuild;
}

/// Global registry mapping client [Type] → [ClientDescriptor].
///
/// Populated at application startup via [XRay.registerClient].
final Map<Type, ClientDescriptor<Object>> clientRegistry = {};

/// Looks up the descriptor for type [T], or `null` if not registered.
ClientDescriptor<T>? descriptorFor<T extends Object>() =>
    clientRegistry[T] as ClientDescriptor<T>?;

/// Convenience accessor: namespace string for a registered type [T].
String namespaceFor<T extends Object>() =>
    (clientRegistry[T]?.namespace) ??
    awsServiceNamespaces[T.toString()] ??
    'aws';
