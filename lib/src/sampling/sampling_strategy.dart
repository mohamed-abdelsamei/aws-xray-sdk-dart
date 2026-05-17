/// Input to the sampling decision.
final class SamplingRequest {
  const SamplingRequest({
    required this.serviceName,
    required this.httpMethod,
    required this.urlPath,
    this.host,
  });

  final String serviceName;
  final String httpMethod;
  final String urlPath;
  final String? host;
}

/// Determines whether a given request should be traced.
abstract interface class SamplingStrategy {
  bool shouldSample(SamplingRequest request);
}
