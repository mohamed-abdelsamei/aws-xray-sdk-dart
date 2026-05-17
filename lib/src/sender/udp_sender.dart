import 'dart:developer' as dev;
import 'dart:io';
import '../models/segment.dart';
import 'segment_encoder.dart';
import 'sender.dart';

/// Sends segments to the X-Ray daemon via UDP (fire-and-forget).
final class UdpSender extends Sender {
  UdpSender({
    this.host = '127.0.0.1',
    this.port = 2000,
  });

  final String host;
  final int port;

  // Sockets keyed by address type so IPv4 and IPv6 are bound correctly.
  RawDatagramSocket? _ipv4Socket;
  RawDatagramSocket? _ipv6Socket;

  /// Returns (or lazily creates) a socket whose address family matches
  /// [address]. This ensures we never try to send an IPv6 datagram through
  /// a socket bound to `anyIPv4` and vice-versa.
  Future<RawDatagramSocket> _getSocket(InternetAddress address) async {
    if (address.type == InternetAddressType.IPv6) {
      return _ipv6Socket ??=
          await RawDatagramSocket.bind(InternetAddress.anyIPv6, 0);
    }
    return _ipv4Socket ??=
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  }

  @override
  Future<void> send(Segment segment) => sendPackets(encode(segment));

  @override
  Future<void> sendPackets(List<List<int>> packets) async {
    if (packets.isEmpty) return;
    // Resolve host first so we can bind the correct address family.
    final address = (await InternetAddress.lookup(host)).first;
    final socket = await _getSocket(address);

    dev.log(
        'aws_xray_sdk: sendPackets ${packets.length} packet(s) → $host:$port',
        name: 'XRay');
    for (final (i, payload) in packets.indexed) {
      try {
        final sent = socket.send(payload, address, port);
        dev.log(
            'aws_xray_sdk: packet[$i] ${payload.length}B → sent=$sent bytes',
            name: 'XRay');
      } catch (e) {
        dev.log('aws_xray_sdk: packet[$i] UDP send failed: $e', name: 'XRay');
      }
    }
  }

  @override
  Future<void> close() async {
    _ipv4Socket?.close();
    _ipv6Socket?.close();
    _ipv4Socket = null;
    _ipv6Socket = null;
  }
}
