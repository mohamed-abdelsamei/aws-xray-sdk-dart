import 'dart:async';
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

    test('host/port open() preserves plain HTTP scheme', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req =
            await client.open('GET', '127.0.0.1', server.port, '/test-path');
        final res = await req.close();
        await res.drain<void>();
        client.close();
      });

      final sub = sender.lastSubs.first as Map;
      final http = sub['http'] as Map;
      final request = http['request'] as Map;
      expect(request['url'], 'http://127.0.0.1:${server.port}/test-path');
    });

    test('detachSocket ends the traced subsegment path', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', serverUri);
        final res = await req.close();
        final socket = await res.detachSocket();
        socket.destroy();
        client.close();
      });

      expect(sender.lastSubs, hasLength(1));
      final sub = sender.lastSubs.first as Map;
      final http = sub['http'] as Map;
      final request = http['request'] as Map;
      expect(request['url'], serverUri.toString());
      expect(http['response']['status'], 200);
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
      expect(request['traced'], isTrue);
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
      final cause = sub['cause'] as Map;
      final exc = (cause['exceptions'] as List).first as Map;
      expect(exc['type'], 'HTTP 500');
      expect(exc['message'], contains('500'));
      expect(exc['remote'], isTrue);
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
      final request = (sub['http'] as Map)['request'] as Map;
      expect(request['traced'], isNull);
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

    test('openUrl preserves an explicit https scheme in the recorded URL',
        () async {
      // A request to an explicit https URL must keep the https scheme on the
      // recorded subsegment (it must not be rewritten to http). The connection
      // to the refused port fails, faulting the subsegment, but the URL is
      // recorded from the request the caller made.
      final httpsUri = Uri.parse('https://127.0.0.1:1/secure');

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        try {
          final req = await client.openUrl('GET', httpsUri);
          await req.close();
        } on SocketException {
          // Expected — connection refused.
        } on HandshakeException {
          // Also acceptable — TLS handshake against a non-TLS/closed port.
        } finally {
          client.close();
        }
      });

      final sub = sender.lastSubs.first as Map;
      expect(sub['fault'], isTrue);
      final request = (sub['http'] as Map)['request'] as Map;
      expect(request['url'], 'https://127.0.0.1:1/secure');
      expect(request['traced'], isNull);
    });

    test('a body stream that errors then completes records one subsegment',
        () async {
      // Server announces 100 bytes but writes a few then drops the socket, so
      // the client's body stream emits an error followed by done. The traced
      // subsegment must be recorded exactly once (faulted), not twice.
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\n'
          'Content-Length: 100\r\n'
          '\r\n'
          'partial',
        );
        await socket.flush();
        await socket.close();
        socket.destroy();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/truncated');

      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        try {
          final req = await client.openUrl('GET', uri);
          final res = await req.close();
          // Consume with cancelOnError: false so the stream delivers the
          // truncation error AND the subsequent done — the interleaving the
          // double-record bug depends on.
          final done = Completer<void>();
          res.listen(
            (_) {},
            onError: (_) {},
            onDone: done.complete,
            cancelOnError: false,
          );
          await done.future;
        } finally {
          client.close();
        }
      });

      // The bug this guards against recorded the subsegment twice (failSubsegment
      // from handleError + endSubsegment from the following handleDone).
      expect(sender.lastSubs, hasLength(1));
      expect((sender.lastSubs.first as Map)['fault'], isTrue);
    });

    test('un-drained response is swept as one incomplete subsegment', () async {
      final segment = tracer.beginSegment();
      await tracer.run(segment, () async {
        final client = XRayHttpClient(HttpClient(), tracer);
        final req = await client.openUrl('GET', serverUri);
        final res = await req.close();
        expect(res.statusCode, 200);
        // Intentionally never drain res.
        client.close();
      });

      expect(sender.lastSubs, hasLength(1));
      final sub = sender.lastSubs.first as Map;
      expect(((sub['metadata'] as Map)['xray'] as Map)['incomplete'], isTrue);
      expect((sub['http'] as Map)['response']['status'], 200);
      expect(sub['in_progress'], isNull);
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
