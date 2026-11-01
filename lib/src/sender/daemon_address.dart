import 'dart:io';

/// The daemon address used when `AWS_XRAY_DAEMON_ADDRESS` is unset or
/// malformed — the X-Ray daemon's documented default.
const defaultDaemonHost = '127.0.0.1';

/// The daemon UDP port used when none is given or the input is malformed.
const defaultDaemonPort = 2000;

const _fallback = (defaultDaemonHost, defaultDaemonPort);

/// Parses an `AWS_XRAY_DAEMON_ADDRESS` value into `(host, port)`.
///
/// Accepts the forms the AWS SDKs and the Lambda runtime actually set:
///  * `host:port` — e.g. `127.0.0.1:2000`, `xray:3000`;
///  * `[v6]:port` — a bracketed IPv6 literal, e.g. `[::1]:2000`;
///  * a bare IPv6 literal — e.g. `::1`, which gets the default port (it
///    cannot carry a port unbracketed, so splitting on the last `:` would
///    mangle it);
///  * `tcp:h:p udp:h:p`, in either order — the dual form Lambda and the
///    daemon docs use. Only the `udp:` part matters here, since segments are
///    sent over UDP; a `tcp:`-only value, or one mixing prefixed and
///    unprefixed parts, is treated as malformed.
///
/// A port is 1 to 5 decimal digits in 1..65535 (leading zeros allowed).
///
/// **Never throws.** This runs inside `XRay.configure` at startup, and a typo
/// in an environment variable must not crash the application. Any malformed
/// input (non-numeric or out-of-range port, empty host, unbalanced brackets,
/// unrecognized multi-part values) falls back to `127.0.0.1:2000` as a
/// whole — we never mix a parsed host with a default port from a bad value,
/// because a half-parsed address is harder to diagnose than the default.
(String, int) parseDaemonAddress(String? value) {
  final trimmed = value?.trim() ?? '';
  if (trimmed.isEmpty) return _fallback;

  final parts = trimmed.split(RegExp(r'\s+'));
  bool isProtocolPart(String p) => p.startsWith('tcp:') || p.startsWith('udp:');
  if (parts.any(isProtocolPart)) {
    // Every part must be prefixed: `udp:h:p garbage` is malformed, not a
    // udp address with trailing noise.
    if (parts.length > 2 || !parts.every(isProtocolPart)) return _fallback;
    final udp = parts.where((p) => p.startsWith('udp:')).toList();
    if (udp.length != 1) return _fallback;
    return _parseHostPort(udp.single.substring('udp:'.length)) ?? _fallback;
  }
  if (parts.length != 1) return _fallback;
  return _parseHostPort(trimmed) ?? _fallback;
}

/// Parses a single address with no protocol prefix; null when malformed.
(String, int)? _parseHostPort(String value) {
  if (value.isEmpty) return null;

  if (value.startsWith('[')) {
    final close = value.indexOf(']');
    if (close <= 1) return null;
    final host = value.substring(1, close);
    if (!_isIPv6(host)) return null;
    final rest = value.substring(close + 1);
    if (rest.isEmpty) return (host, defaultDaemonPort);
    if (!rest.startsWith(':')) return null;
    final port = _parsePort(rest.substring(1));
    return port == null ? null : (host, port);
  }

  final colons = ':'.allMatches(value).length;
  if (colons == 0) return (value, defaultDaemonPort);
  if (colons > 1) return _isIPv6(value) ? (value, defaultDaemonPort) : null;

  final sep = value.indexOf(':');
  final host = value.substring(0, sep);
  final port = _parsePort(value.substring(sep + 1));
  if (host.isEmpty || port == null) return null;
  return (host, port);
}

/// Accepts 1 to 5 ASCII digits only, so `int.tryParse` leniency (`+80`,
/// `0x7d0`, surrounding whitespace) is rejected. Leading zeros are allowed
/// (`03000` is port 3000). The value must be in 1..65535.
int? _parsePort(String s) {
  if (!RegExp(r'^\d{1,5}$').hasMatch(s)) return null;
  final port = int.parse(s);
  if (port < 1 || port > 65535) return null;
  return port;
}

/// Pure string parsing (no socket or DNS) — [InternetAddress.tryParse] only
/// inspects the literal.
bool _isIPv6(String s) =>
    InternetAddress.tryParse(s)?.type == InternetAddressType.IPv6;
