import 'dart:math';

final _rng = Random.secure();

/// Returns a [length]-character lowercase hexadecimal string using
/// a cryptographically secure random number generator.
String randomHex(int length) {
  final buf = StringBuffer();
  for (var i = 0; i < length; i++) {
    buf.write(_rng.nextInt(16).toRadixString(16));
  }
  return buf.toString();
}

/// Returns the current time as seconds since the Unix epoch (floating-point).
double nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000.0;

const _maxMessageLength = 1024;
const _truncationMarker = '…[truncated]';

/// Caps a recorded exception message at 1024 UTF-16 code units and appends
/// `…[truncated]`. Never leaves a lone high surrogate at the cut.
String truncateMessage(String s) {
  if (s.length <= _maxMessageLength) return s;
  var end = _maxMessageLength;
  final last = s.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return s.substring(0, end) + _truncationMarker;
}
