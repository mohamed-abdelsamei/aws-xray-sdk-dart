import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('UdpSender', () {
    late RawDatagramSocket server;
    late int serverPort;

    setUp(() async {
      server = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      serverPort = server.port;
    });

    tearDown(() async {
      server.close();
    });

    Future<String> receivePayload() async {
      final completer = Completer<String>();
      server.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = server.receive()!;
          completer.complete(utf8.decode(dg.data));
        }
      });
      return completer.future.timeout(const Duration(seconds: 2));
    }

    test('sends a valid X-Ray header+JSON payload', () async {
      final sender = UdpSender(host: '127.0.0.1', port: serverPort);
      final segment = Segment.begin(
        name: 'test-svc',
        traceId: TraceId.generate(),
      ).close();

      final payloadFuture = receivePayload();
      await sender.send(segment);

      final raw = await payloadFuture;
      expect(raw, startsWith('{"format":"json","version":1}\n'));

      final body = raw.substring(raw.indexOf('\n') + 1);
      final json = jsonDecode(body) as Map;
      expect(json['name'], 'test-svc');
      expect(json.containsKey('trace_id'), isTrue);

      await sender.close();
    });

    test('sends segment with subsegments attached', () async {
      final sender = UdpSender(host: '127.0.0.1', port: serverPort);
      final sub = Subsegment.begin(name: 'child', namespace: 'local').close();
      final segment = Segment.begin(
        name: 'parent',
        traceId: TraceId.generate(),
      ).addSubsegment(sub).close();

      final payloadFuture = receivePayload();
      await sender.send(segment);

      final raw = await payloadFuture;
      final body = raw.substring(raw.indexOf('\n') + 1);
      final json = jsonDecode(body) as Map;
      expect((json['subsegments'] as List), hasLength(1));

      await sender.close();
    });

    test('re-uses the same socket across sends', () async {
      final sender = UdpSender(host: '127.0.0.1', port: serverPort);
      final seg =
          Segment.begin(name: 'svc', traceId: TraceId.generate()).close();

      // Receive two packets.
      var count = 0;
      server.listen((event) {
        if (event == RawSocketEvent.read) {
          server.receive();
          count++;
        }
      });

      await sender.send(seg);
      await sender.send(seg);
      await Future.delayed(const Duration(milliseconds: 100));

      expect(count, 2);
      await sender.close();
    });
  });
}
