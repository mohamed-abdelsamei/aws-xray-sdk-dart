import 'package:aws_xray_sdk/aws_xray_sdk.dart';

void main() async {
  print('=== X-Ray Sampling Strategy Examples ===\n');

  // 1. Fixed rate — always sample (useful for development).
  print('1. Fixed Rate Sampler (100%):');
  final alwaysTracer = XRayTracer(
    serviceName: 'fixed-rate-service',
    sender: NoopSender(),
    sampling: FixedRateSampler(1.0),
  );
  await _runOperation(alwaysTracer, 'op-always');

  // 2. Fixed rate — 10% sampling.
  print('\n2. Fixed Rate Sampler (10%):');
  final lowRateTracer = XRayTracer(
    serviceName: 'low-rate-service',
    sender: NoopSender(),
    sampling: FixedRateSampler(0.1),
  );
  for (var i = 0; i < 5; i++) {
    await _runOperation(lowRateTracer, 'op-$i');
  }

  // 3. Reservoir — 2 req/s always sampled, 5% rate above that.
  print('\n3. Reservoir Sampler (2 req/s + 5%):');
  final reservoirTracer = XRayTracer(
    serviceName: 'reservoir-service',
    sender: NoopSender(),
    sampling: ReservoirSampler(reservoirSize: 2, fixedRate: 0.05),
  );
  for (var i = 0; i < 5; i++) {
    await _runOperation(reservoirTracer, 'burst-op-$i');
  }

  // 4. Custom strategy — sample based on URL path.
  print('\n4. Custom Strategy (path-based):');
  final customTracer = XRayTracer(
    serviceName: 'custom-sampling-service',
    sender: NoopSender(),
    sampling: _PathBasedSampler(),
  );
  for (final path in ['/api/users', '/health', '/api/orders', '/metrics']) {
    await _runOperation(customTracer, path);
  }
}

Future<void> _runOperation(XRayTracer tracer, String name) async {
  final segment = Segment.begin(
    name: name,
    traceId: TraceId.generate(),
  );
  await tracer.run(segment, () async {
    await Future.delayed(const Duration(milliseconds: 10));
    print('  ran: $name');
  });
}

/// Samples only paths that start with /api.
class _PathBasedSampler implements SamplingStrategy {
  @override
  bool shouldSample(SamplingRequest request) =>
      request.urlPath.startsWith('/api');
}
