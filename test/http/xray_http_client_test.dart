import 'dart:convert';
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

class _RecordingSender extends Sender {
  final List<Map<String, Object?>> sent = [];

  @override
  Future<void> send(Segment segment) async {
    sent.add(jsonDecode(jsonEncode(segment.toJson())) as Map<String, Object?>);
  }

  @override
  Future<void> close() async {}

  bool get isEmpty => sent.isEmpty;
  Map<String, Object?> get last => sent.last;
  List get lastSubs => last['subsegments'] as List? ?? const [];
}

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
      expect(HttpOverrides.current, isNot(same(first)));

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
      final client = HttpClient();
      expect(client, isNotNull);
      client.close();
      XRay.unpatchHttp();
    });
  });

  // ── Core XRayHttpClient tracing behaviour ──────────────────────────────────

  group('XRayHttpClient — tracing', () {
    late HttpServer server;
    late _RecordingSender sender;
    late XRayTracer tracer;
    late Uri serverUri;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response
          ..statusCode = 200
          ..close();
      });
      serverUri = Uri.parse('http://127.0.0.1:${server.port}/test-path');

      sender = _RecordingSender();
      tracer = XRayTracer(
        serviceName: 'svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
      );
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('creates a subsegment for each outbound request', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', serverUri);
        final res = await req.close();
        await res.drain<void>();
        client.close();
      });

      expect(sender.lastSubs, hasLength(1));
      final sub = sender.lastSubs.first as Map;
      expect(sub['name'], '127.0.0.1');
    });

    test('injects X-Amzn-Trace-Id header on the request', () async {
      String? capturedHeader;
      // Replace server with one that captures the header.
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        capturedHeader = req.headers.value('x-amzn-trace-id');
        req.response
          ..statusCode = 200
          ..close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', uri);
        final res = await req.close();
        await res.drain<void>();
        client.close();
      });

      expect(capturedHeader, isNotNull);
      expect(capturedHeader, contains('Root='));
      expect(capturedHeader, contains('Parent='));
      expect(capturedHeader, contains('Sampled=1'));
    });

    test('subsegment records HTTP method and URL', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', serverUri);
        final res = await req.close();
        await res.drain<void>();
        client.close();
      });

      final sub = sender.lastSubs.first as Map;
      final http = sub['http'] as Map;
      final request = http['request'] as Map;
      expect(request['method'], 'GET');
      expect(request['url'], serverUri.toString());
    });

    test('subsegment records HTTP response status code', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response
          ..statusCode = 404
          ..close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', uri);
        final res = await req.close();
        await res.drain<void>();
        client.close();
      });

      final sub = sender.lastSubs.first as Map;
      final http = sub['http'] as Map;
      final response = http['response'] as Map;
      expect(response['status'], 404);
    });

    test('5xx response marks subsegment as fault', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response
          ..statusCode = 500
          ..close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', uri);
        final res = await req.close();
        await res.drain<void>();
        client.close();
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['fault'], isTrue);
    });

    test('4xx response marks subsegment as error', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response
          ..statusCode = 400
          ..close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', uri);
        final res = await req.close();
        await res.drain<void>();
        client.close();
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['error'], isTrue);
    });

    test('429 response marks subsegment as throttle + error', () async {
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response
          ..statusCode = 429
          ..close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', uri);
        final res = await req.close();
        await res.drain<void>();
        client.close();
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['throttle'], isTrue);
      expect(sub['error'], isTrue);
    });

    test('connection failure marks subsegment as faulted', () async {
      // Port 1 is refused on loopback.
      final badUri = Uri.parse('http://127.0.0.1:1/');

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        try {
          final req = await client.openUrl('GET', badUri);
          await req.close();
        } on SocketException {
          // Expected — connection refused.
        } finally {
          client.close();
        }
      });

      expect(sender.lastSubs, hasLength(1));
      final sub = sender.lastSubs.first as Map;
      expect(sub['fault'], isTrue);
    });

    test('no subsegment created when there is no active segment', () async {
      // openUrl outside tracer.run() — currentSegment is null, passes through.
      final client = XRayHttpClient(HttpClient(), tracer);
      final req = await client.openUrl('GET', serverUri);
      final res = await req.close();
      await res.drain<void>();
      client.close();

      expect(sender.isEmpty, isTrue);
    });

    test('non-AWS host gets remote namespace', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', serverUri);
        final res = await req.close();
        await res.drain<void>();
        client.close();
      });

      final sub = sender.lastSubs.first as Map;
      // 127.0.0.1 is not amazonaws.com → namespace must be 'remote'.
      expect(sub['namespace'], 'remote');
    });

    test('multiple requests each produce their own subsegment', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        for (var i = 0; i < 3; i++) {
          final req = await client.openUrl('GET', serverUri);
          final res = await req.close();
          await res.drain<void>();
        }
        client.close();
      });

      expect(sender.lastSubs, hasLength(3));
    });
  });
}

class _NoopOverrides extends HttpOverrides {}
