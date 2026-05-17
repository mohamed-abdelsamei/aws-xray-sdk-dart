import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('XRay.patchHttp / unpatchHttp', () {
    late XRayTracer tracer;

    setUp(() {
      tracer = XRayTracer(
        serviceName: 'http-test',
        sender: NoopSender(),
        sampling: FixedRateSampler(1.0),
      );
    });

    tearDown(() {
      // Always restore global overrides after each test.
      XRay.unpatchHttp();
    });

    test('patchHttp installs XRayHttpOverrides globally', () {
      XRay.patchHttp(tracer);
      expect(HttpOverrides.current, isNotNull);
    });

    test('unpatchHttp restores previous overrides', () {
      final previous = HttpOverrides.current;
      XRay.patchHttp(tracer);
      XRay.unpatchHttp();
      expect(HttpOverrides.current, same(previous));
    });

    test('patchHttp chains over existing overrides', () {
      final first = _NoopOverrides();
      HttpOverrides.global = first;

      XRay.patchHttp(tracer);

      // Current override should be the XRay one (not the first one directly).
      expect(HttpOverrides.current, isNot(same(first)));

      // After unpatching, the previous override is restored.
      XRay.unpatchHttp();
      expect(HttpOverrides.current, same(first));

      HttpOverrides.global = null;
    });

    test('createHttpClient returns an HttpClient after patching', () {
      XRay.patchHttp(tracer);
      final client = HttpOverrides.current!.createHttpClient(null);
      expect(client, isA<HttpClient>());
      client.close();
    });
  });

  group('XRayHttpOverrides', () {
    test('does not affect HttpClient when no active segment', () async {
      final tracer = XRayTracer(
        serviceName: 'svc',
        sender: NoopSender(),
        sampling: FixedRateSampler(1.0),
      );
      XRay.patchHttp(tracer);

      // No run() → currentSegment is null → tracing is skipped silently.
      // We just verify no exception is thrown when creating the client.
      final client = HttpClient();
      expect(client, isNotNull);
      client.close();

      XRay.unpatchHttp();
    });
  });
}

class _NoopOverrides extends HttpOverrides {}
