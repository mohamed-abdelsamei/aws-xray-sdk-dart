// A datagram the OS refuses (RawDatagramSocket.send returning fewer bytes than
// the payload, without throwing) is a failure: it is reported, the poisoned
// socket is dropped and closed, and later sends rebind a fresh one. Every
// socket here is an injected fake; no real socket is opened.
import 'dart:async';
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

// Mimics a socket the OS has wedged: once [refuseFrom] sends have happened,
// every send returns 0 instead of throwing.
class _FakeSocket implements RawDatagramSocket {
  _FakeSocket({this.refuseFrom = 0});

  final int refuseFrom;
  final sent = <List<int>>[];
  int attempts = 0;
  bool closed = false;

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (closed) throw const SocketException('socket closed');
    attempts++;
    if (attempts > refuseFrom) return 0;
    sent.add(buffer);
    return buffer.length;
  }

  @override
  void close() => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('UdpSender short send', () {
    test('a zero-byte send is reported and the next send rebinds', () async {
      final sockets = <_FakeSocket>[];
      final errors = <Object>[];
      final sender = UdpSender(
        onError: errors.add,
        socketFactory: (_) async {
          // First socket refuses everything; later ones work.
          final s = _FakeSocket(refuseFrom: sockets.isEmpty ? 0 : 1 << 30);
          sockets.add(s);
          return s;
        },
      );

      await sender.sendPackets([List.filled(70000, 1)]);

      expect(errors, hasLength(1));
      expect(errors.single, isA<SocketException>());
      expect(errors.single.toString(), contains('70000'));
      expect(sockets.first.closed, isTrue);

      await sender.sendPackets([
        [1, 2, 3]
      ]);

      expect(sockets, hasLength(2), reason: 'must rebind a fresh socket');
      expect(sockets[1].sent, [
        [1, 2, 3]
      ]);
      expect(errors, hasLength(1));
      await sender.close();
    });

    test('the rest of the batch still goes out on a fresh socket', () async {
      final sockets = <_FakeSocket>[];
      final errors = <Object>[];
      final sender = UdpSender(
        onError: errors.add,
        socketFactory: (_) async {
          // First socket accepts one datagram, then is wedged.
          final s = _FakeSocket(refuseFrom: sockets.isEmpty ? 1 : 1 << 30);
          sockets.add(s);
          return s;
        },
      );

      await sender.sendPackets([
        [1],
        [2],
        [3],
      ]);

      expect(errors, hasLength(1));
      expect(sockets.first.sent, [
        [1]
      ]);
      expect(sockets, hasLength(2));
      expect(sockets[1].sent, [
        [3]
      ]);
      await sender.close();
    });

    test('concurrent senders share the rebind; none uses a closed socket',
        () async {
      final sockets = <_FakeSocket>[];
      final errors = <Object>[];
      final gate = Completer<void>();
      final sender = UdpSender(
        onError: errors.add,
        socketFactory: (_) async {
          final first = sockets.isEmpty;
          final s = _FakeSocket(refuseFrom: first ? 0 : 1 << 30);
          sockets.add(s);
          if (first) await gate.future; // let every sender join this attempt
          return s;
        },
      );

      final sends = [
        sender.sendPackets([List.filled(70000, 1)]),
        sender.sendPackets([
          [2]
        ]),
        sender.sendPackets([
          [3]
        ]),
      ];
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await Future.wait(sends);

      expect(errors, hasLength(1), reason: 'only the refused datagram fails');
      expect(sockets, hasLength(2), reason: 'one shared rebind');
      expect(sockets[1].sent, [
        [2],
        [3]
      ]);
      await sender.close();
    });
  });
}
