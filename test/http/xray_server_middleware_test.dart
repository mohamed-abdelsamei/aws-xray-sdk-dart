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

  Map<String, Object?> get last => sent.last;
}

void main() {
  group('handleTraced', () {
    late HttpServer server;
    late _RecordingSender sender;

    // Builds a tracer with the given sampling rate, serves one request through
    // handleTraced, and returns the response's x-amzn-trace-id header.
    Future<String?> serveAndCapture({
      required double rate,
      String? requestTraceHeader,
      Future<void> Function()? handler,
    }) async {
      sender = _RecordingSender();
      final tracer = XRayTracer(
        serviceName: 'edge-svc',
        sender: sender,
        sampling: FixedRateSampler(rate),
      );

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        await handleTraced(req, tracer, () async {
          await handler?.call();
          req.response.statusCode = 200;
        });
        await req.response.close();
      });

      final client = HttpClient();
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:${server.port}/orders'));
      if (requestTraceHeader != null) {
        req.headers.set('x-amzn-trace-id', requestTraceHeader);
      }
      final res = await req.close();
      final header = res.headers.value('x-amzn-trace-id');
      await res.drain<void>();
      client.close();
      return header;
    }

    tearDown(() async {
      await server.close(force: true);
    });

    test('response header carries Sampled=1 for a sampled trace', () async {
      final header = await serveAndCapture(rate: 1.0);
      expect(header, isNotNull);
      expect(header, contains('Sampled=1'));
    });

    test('response header carries Sampled=0 for an unsampled trace', () async {
      // Guards the bug where isSampled was read outside the run zone (fail-open
      // to true), always emitting Sampled=1 regardless of the real decision.
      final header = await serveAndCapture(rate: 0.0);
      expect(header, isNotNull);
      expect(header, contains('Sampled=0'));
    });

    test('continues the upstream trace id and parent', () async {
      final upstreamTrace = TraceId.generate();
      final upstream = 'Root=$upstreamTrace;Parent=1111aaaa2222bbbb;Sampled=1';

      await serveAndCapture(rate: 1.0, requestTraceHeader: upstream);

      final seg = sender.last;
      expect(seg['trace_id'], upstreamTrace.toString());
      expect(seg['parent_id'], '1111aaaa2222bbbb');
    });

    test('response header reuses the same root trace id', () async {
      final upstreamTrace = TraceId.generate();
      final header = await serveAndCapture(
        rate: 1.0,
        requestTraceHeader: 'Root=$upstreamTrace;Sampled=1',
      );
      expect(header, contains('Root=$upstreamTrace'));
    });

    test('records request and response http data on the segment', () async {
      await serveAndCapture(rate: 1.0);

      final http = sender.last['http'] as Map<String, Object?>;
      final request = http['request'] as Map<String, Object?>;
      final response = http['response'] as Map<String, Object?>;

      expect(request['method'], 'GET');
      expect(request['url'], contains('/orders'));
      expect(request['traced'], true);
      expect(response['status'], 200);
    });

    test('runs the handler inside an active trace zone', () async {
      Segment? captured;
      final upstreamTrace = TraceId.generate();
      // The handler reads the active segment via a fresh tracer call; assert it
      // is the continued trace, proving the handler ran inside run().
      sender = _RecordingSender();
      final tracer = XRayTracer(
        serviceName: 'edge-svc',
        sender: sender,
        sampling: FixedRateSampler(1.0),
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        await handleTraced(req, tracer, () async {
          captured = tracer.currentSegment;
          req.response.statusCode = 200;
        });
        await req.response.close();
      });

      final client = HttpClient();
      final r =
          await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/x'))
            ..headers.set('x-amzn-trace-id', 'Root=$upstreamTrace;Sampled=1');
      final res = await r.close();
      await res.drain<void>();
      client.close();

      expect(captured, isNotNull);
      expect(captured!.traceId.toString(), upstreamTrace.toString());
    });
  });
}
