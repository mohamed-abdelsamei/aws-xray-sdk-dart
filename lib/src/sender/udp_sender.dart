import 'dart:io';
import '../models/segment.dart';
import 'segment_encoder.dart';
import 'sender.dart';

/// Sends segments to the X-Ray daemon via UDP (fire-and-forget).
///
/// The daemon address is resolved and a socket bound **at most once** (memoized
/// as a single in-flight future), so there is no per-send DNS lookup and no
/// bind race when multiple segments are flushed concurrently.
///
/// **No delivery acknowledgment.** UDP is fire-and-forget: a datagram sent to a
/// daemon that is not listening still succeeds locally. A failure here never
/// faults the traced operation, and [onError] surfaces only *local* failures
/// (network unreachable, message too large, resolve/bind failure) — never
/// "the daemon did not receive it". To confirm delivery, check the X-Ray daemon
/// or console.
final class UdpSender extends Sender {
  UdpSender({
    this.host = '127.0.0.1',
    this.port = 2000,
    this.onError,
    Future<InternetAddress> Function(String host)? resolver,
    Future<RawDatagramSocket> Function(InternetAddressType family)?
        socketFactory,
  })  : _resolve = resolver ?? _defaultResolve,
        _bind = socketFactory ?? _defaultBind;

  final String host;
  final int port;

  /// Called with the error when a resolution, bind, or datagram send fails.
  ///
  /// Optional; when null (the default) failures are silent. Invoked
  /// synchronously and best-effort — a returned [Future] is not awaited, and an
  /// exception it throws is ignored (it cannot break the sender).
  ///
  /// Note: UDP has no delivery acknowledgment, so this surfaces only **local**
  /// failures (network unreachable, message too large, resolve/bind failure) —
  /// it does **not** fire when the daemon is simply not listening.
  final void Function(Object error)? onError;

  // Host resolution and socket binding seams. Default to the dart:io
  // implementations; tests inject counting/suspending/failing variants to
  // verify the memoization and failure behavior. Not intended for production
  // use.
  final Future<InternetAddress> Function(String host) _resolve;
  final Future<RawDatagramSocket> Function(InternetAddressType family) _bind;

  // The daemon connection (resolved address + bound socket), created at most
  // once. Stored as the in-flight future so concurrent sends share a single
  // initialization rather than each binding their own socket.
  Future<_Conn>? _conn;

  @override
  Future<void> send(Segment segment) => sendPackets(encode(segment));

  @override
  Future<void> sendPackets(List<List<int>> packets) async {
    if (packets.isEmpty) return;
    // Total containment: a resolution, bind, or send failure must never escape
    // into the traced operation. Tracing is fire-and-forget.
    final _Conn conn;
    try {
      conn = await _obtainConn();
    } catch (e) {
      _report(e); // resolution or bind failure
      return;
    }
    for (final payload in packets) {
      try {
        conn.socket.send(payload, conn.address, port);
      } catch (e) {
        // A single datagram failure must not abort the rest of the batch.
        _report(e);
      }
    }
  }

  /// Reports [error] to [onError], guarded so a throwing callback cannot break
  /// the sender.
  void _report(Object error) {
    final cb = onError;
    if (cb == null) return;
    try {
      cb(error);
    } catch (_) {
      // A misbehaving onError must never fault the tracing path.
    }
  }

  /// The memoized connection, creating it on first use.
  ///
  /// Concurrent callers share a single in-flight attempt (no per-send DNS
  /// stampede). A *successful* attempt is cached for the process; a *failed*
  /// attempt is cleared so the next send retries — important when the daemon or
  /// DNS is not ready at first send.
  Future<_Conn> _obtainConn() {
    final existing = _conn;
    if (existing != null) return existing;

    final pending = _connect();
    _conn = pending;
    // Drop the memo if this attempt fails, without clobbering a newer one. This
    // listener handles its own error copy, so the failure is never "unhandled";
    // the awaiting send still receives (and contains) the rejection.
    pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {
        if (identical(_conn, pending)) _conn = null;
      },
    );
    return pending;
  }

  Future<_Conn> _connect() async {
    // Fast path: when the daemon host is already an IP literal (the common case
    // — `127.0.0.1` and the link-local Lambda address `169.254.100.1`), skip
    // DNS resolution entirely and bind straight away.
    final address = InternetAddress.tryParse(host) ?? await _resolve(host);
    final socket = await _bind(address.type);
    return _Conn(address, socket);
  }

  @override
  Future<void> close() async {
    final conn = _conn;
    _conn = null;
    if (conn != null) {
      try {
        (await conn).socket.close();
      } catch (_) {
        // Connection never completed (or already closed) — nothing to release.
      }
    }
  }

  static Future<InternetAddress> _defaultResolve(String host) async =>
      (await InternetAddress.lookup(host)).first;

  static Future<RawDatagramSocket> _defaultBind(InternetAddressType family) =>
      RawDatagramSocket.bind(
        family == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0,
      );
}

/// A resolved daemon address paired with the socket bound to reach it.
class _Conn {
  _Conn(this.address, this.socket);
  final InternetAddress address;
  final RawDatagramSocket socket;
}
