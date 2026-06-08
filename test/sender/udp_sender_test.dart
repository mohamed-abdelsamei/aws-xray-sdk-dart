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

  // Resolution + bind happen at most once and are race-free, using the
  // injectable resolver/socketFactory seam (with fakes that suspend across a
  // microtask so the begin/await interleaving is actually exercised).
  group('UdpSender — connection memoization', () {
    test('resolves and binds once across multiple sends', () async {
      var resolveCount = 0;
      var bindCount = 0;
      final sender = UdpSender(
        host: 'daemon.example', // a hostname, to exercise resolution
        port: 2000,
        resolver: (h) async {
          resolveCount++;
          return InternetAddress('127.0.0.1');
        },
        socketFactory: (f) async {
          bindCount++;
          return RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        },
      );

      await sender.sendPackets([
        [1, 2, 3]
      ]);
      await sender.sendPackets([
        [4, 5, 6]
      ]);
      await sender.sendPackets([
        [7, 8, 9]
      ]);

      expect(resolveCount, 1);
      expect(bindCount, 1);
      await sender.close();
    });

    test('an IP-literal host binds only once across sends (memo)', () async {
      var bindCount = 0;
      final sender = UdpSender(
        host: '127.0.0.1',
        socketFactory: (f) async {
          bindCount++;
          return RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        },
      );

      await sender.sendPackets([
        [1]
      ]);
      await sender.sendPackets([
        [2]
      ]);
      await sender.sendPackets([
        [3]
      ]);

      expect(bindCount, 1);
      await sender.close();
    });

    test('concurrent sends bind exactly one socket (no race)', () async {
      var resolveCount = 0;
      var bindCount = 0;
      final sender = UdpSender(
        host: 'daemon.example',
        // Suspend across a microtask so the begin/await interleaving is actually
        // exercised — a synchronous fake would pass even against the old `??=`.
        resolver: (h) async {
          resolveCount++;
          await Future<void>.delayed(Duration.zero);
          return InternetAddress('127.0.0.1');
        },
        socketFactory: (f) async {
          bindCount++;
          await Future<void>.delayed(Duration.zero);
          return RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        },
      );

      await Future.wait([
        for (var i = 0; i < 5; i++)
          sender.sendPackets([
            [i]
          ]),
      ]);

      expect(resolveCount, 1);
      expect(bindCount, 1);
      await sender.close();
    });
  });

  // An IP-literal host must never hit the resolver.
  group('UdpSender — IP-literal fast path', () {
    Future<void> expectNoResolution(String host) async {
      var resolveCount = 0;
      final sender = UdpSender(
        host: host,
        resolver: (h) async {
          resolveCount++;
          return InternetAddress('127.0.0.1');
        },
        socketFactory: (f) async => RawDatagramSocket.bind(
          f == InternetAddressType.IPv6
              ? InternetAddress.anyIPv6
              : InternetAddress.anyIPv4,
          0,
        ),
      );
      await sender.sendPackets([
        [1]
      ]);
      expect(resolveCount, 0, reason: 'IP literal $host must skip resolution');
      await sender.close();
    }

    test(
        'IPv4 literal skips resolution', () => expectNoResolution('127.0.0.1'));
    test('link-local Lambda address skips resolution',
        () => expectNoResolution('169.254.100.1'));
    test('IPv6 literal skips resolution', () => expectNoResolution('::1'));
  });

  // Resolution / bind / send failures never escape sendPackets.
  group('UdpSender — total error containment', () {
    test('a resolution failure does not escape', () async {
      final sender = UdpSender(
        host: 'daemon.example',
        resolver: (h) async => throw const SocketException('dns down'),
        socketFactory: (f) async =>
            RawDatagramSocket.bind(InternetAddress.anyIPv4, 0),
      );
      await expectLater(
        sender.sendPackets([
          [1]
        ]),
        completes,
      );
      await sender.close();
    });

    test('a bind failure does not escape', () async {
      final sender = UdpSender(
        host: '127.0.0.1',
        socketFactory: (f) async => throw const SocketException('no socket'),
      );
      await expectLater(
        sender.sendPackets([
          [1]
        ]),
        completes,
      );
      await sender.close();
    });

    test('send() (segment path) also contains failures', () async {
      final sender = UdpSender(
        host: 'daemon.example',
        resolver: (h) async => throw const SocketException('dns down'),
      );
      final seg =
          Segment.begin(name: 'svc', traceId: TraceId.generate()).close();
      await expectLater(sender.send(seg), completes);
      await sender.close();
    });
  });

  // The bound socket family matches the resolved address.
  group('UdpSender — socket family', () {
    Future<InternetAddressType?> familyFor(String host) async {
      InternetAddressType? bound;
      final sender = UdpSender(
        host: host,
        socketFactory: (f) async {
          bound = f;
          return RawDatagramSocket.bind(
            f == InternetAddressType.IPv6
                ? InternetAddress.anyIPv6
                : InternetAddress.anyIPv4,
            0,
          );
        },
      );
      await sender.sendPackets([
        [1]
      ]);
      await sender.close();
      return bound;
    }

    test(
        'IPv4 address binds an IPv4 socket',
        () async =>
            expect(await familyFor('127.0.0.1'), InternetAddressType.IPv4));
    test('IPv6 address binds an IPv6 socket',
        () async => expect(await familyFor('::1'), InternetAddressType.IPv6));
  });

  // A failed connect is not cached — retried on the next send — and concurrent
  // sends share one attempt (no DNS stampede).
  group('UdpSender — failed resolution is retried', () {
    test('a failed resolution is retried on the next send, then memoized',
        () async {
      var attempts = 0;
      final sender = UdpSender(
        host: 'daemon.example',
        resolver: (h) async {
          attempts++;
          if (attempts == 1) throw const SocketException('dns down');
          return InternetAddress('127.0.0.1');
        },
        socketFactory: (f) async =>
            RawDatagramSocket.bind(InternetAddress.anyIPv4, 0),
      );

      // 1st send: resolution fails, contained (no throw), nothing cached.
      await sender.sendPackets([
        [1]
      ]);
      expect(attempts, 1);

      // 2nd send: retries and succeeds.
      await sender.sendPackets([
        [2]
      ]);
      expect(attempts, 2);

      // 3rd send: now memoized — no further resolution.
      await sender.sendPackets([
        [3]
      ]);
      expect(attempts, 2);

      await sender.close();
    });

    test('concurrent sends during a failing connect share one attempt',
        () async {
      var attempts = 0;
      final sender = UdpSender(
        host: 'daemon.example',
        resolver: (h) async {
          attempts++;
          await Future<void>.delayed(Duration.zero);
          throw const SocketException('dns down');
        },
        socketFactory: (f) async =>
            RawDatagramSocket.bind(InternetAddress.anyIPv4, 0),
      );

      await Future.wait([
        for (var i = 0; i < 5; i++)
          sender.sendPackets([
            [i]
          ]),
      ]);

      // One shared attempt — no per-send stampede.
      expect(attempts, 1);
      await sender.close();
    });
  });

  // Optional onError surfaces local failures; silent by default; a throwing
  // onError cannot break the sender.
  group('UdpSender — onError callback', () {
    test('onError is invoked on a resolution failure', () async {
      Object? reported;
      final sender = UdpSender(
        host: 'daemon.example',
        resolver: (h) async => throw const SocketException('dns down'),
        onError: (e) => reported = e,
      );
      await sender.sendPackets([
        [1]
      ]);
      expect(reported, isA<SocketException>());
      await sender.close();
    });

    test('onError is invoked on a bind failure', () async {
      Object? reported;
      final sender = UdpSender(
        host: '127.0.0.1',
        socketFactory: (f) async => throw const SocketException('no socket'),
        onError: (e) => reported = e,
      );
      await sender.sendPackets([
        [1]
      ]);
      expect(reported, isA<SocketException>());
      await sender.close();
    });

    test('with no onError, failures are silent (no throw)', () async {
      final sender = UdpSender(
        host: 'daemon.example',
        resolver: (h) async => throw const SocketException('dns down'),
      );
      await expectLater(
        sender.sendPackets([
          [1]
        ]),
        completes,
      );
      await sender.close();
    });

    test('a throwing onError does not break the sender', () async {
      final sender = UdpSender(
        host: 'daemon.example',
        resolver: (h) async => throw const SocketException('dns down'),
        onError: (e) => throw StateError('bad callback'),
      );
      await expectLater(
        sender.sendPackets([
          [1]
        ]),
        completes,
      );
      await sender.close();
    });
  });

  // close() releases the socket and leaves the sender reusable.
  group('UdpSender — re-openable close', () {
    test('a send after close re-initializes the connection', () async {
      var bindCount = 0;
      final sender = UdpSender(
        host: '127.0.0.1',
        socketFactory: (f) async {
          bindCount++;
          return RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        },
      );

      await sender.sendPackets([
        [1]
      ]);
      expect(bindCount, 1);

      await sender.close();

      await sender.sendPackets([
        [2]
      ]);
      expect(bindCount, 2, reason: 'close() should reset the memo');

      await sender.close();
    });
  });

  // An empty payload list does nothing at all.
  group('UdpSender — empty payload no-op', () {
    test('no resolution, bind, or send for an empty list', () async {
      var resolveCount = 0;
      var bindCount = 0;
      final sender = UdpSender(
        host: 'daemon.example',
        resolver: (h) async {
          resolveCount++;
          return InternetAddress('127.0.0.1');
        },
        socketFactory: (f) async {
          bindCount++;
          return RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        },
      );
      await sender.sendPackets([]);
      expect(resolveCount, 0);
      expect(bindCount, 0);
      await sender.close();
    });
  });
}
