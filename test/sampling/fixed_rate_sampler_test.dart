import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  const req = SamplingRequest(
    serviceName: 'svc',
    httpMethod: 'GET',
    urlPath: '/ping',
  );

  group('FixedRateSampler', () {
    test('rate=1.0 always samples', () {
      final s = FixedRateSampler(1.0);
      for (var i = 0; i < 100; i++) {
        expect(s.shouldSample(req), isTrue);
      }
    });

    test('rate=0.0 never samples', () {
      final s = FixedRateSampler(0.0);
      for (var i = 0; i < 100; i++) {
        expect(s.shouldSample(req), isFalse);
      }
    });

    test('rate assertion', () {
      expect(() => FixedRateSampler(1.5), throwsA(isA<AssertionError>()));
      expect(() => FixedRateSampler(-0.1), throwsA(isA<AssertionError>()));
    });
  });
}
