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
///
/// The decision is made **once**, at [XRayTracer.run] entry, and stored in the
/// zone so every downstream subsegment's `X-Amzn-Trace-Id` header carries the
/// same `Sampled=1/0` flag and `closeSegment` consults it instead of
/// re-evaluating. Returning `false` means the segment is built but never sent.
///
/// This package ships **local** strategies only ([FixedRateSampler],
/// [ReservoirSampler]): each isolate decides independently with no coordination
/// and no call to the X-Ray sampling API. There is no centralized-rule fallback
/// — when central rules would be desired, none are consulted; the configured
/// local strategy is always authoritative. (Polling `GetSamplingRules` /
/// `GetSamplingTargets` is a planned, not-yet-implemented feature.)
///
/// Implement this interface to plug in custom logic based on the
/// [SamplingRequest] (service name, HTTP method, URL path, host).
abstract interface class SamplingStrategy {
  bool shouldSample(SamplingRequest request);
}
