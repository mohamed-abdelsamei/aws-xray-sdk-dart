import 'dart:async';
import 'dart:io';

import '../diagnostic.dart';
import '../models/http_data.dart' show redactUrlsInText;
import 'daemon_address.dart';

/// Warns once when [raw] (the `AWS_XRAY_DAEMON_ADDRESS` value) is set but
/// malformed. Unset, blank and valid values report nothing.
///
/// With an [onDiagnostic] hook the warning goes to it as
/// `daemon_address_invalid`; otherwise one line is written through
/// [writeLine] (stderr by default). Never throws: a throwing hook or a closed
/// stderr is ignored, because a typo in an environment variable must not
/// crash startup.
void warnIfDaemonAddressInvalid(
  String? raw, {
  void Function(XRayDiagnostic diagnostic)? onDiagnostic,
  void Function(String line)? writeLine,
}) {
  try {
    if (!isMalformedDaemonAddress(raw)) return;
    final message = 'AWS_XRAY_DAEMON_ADDRESS "${_sanitize(raw!)}" is '
        'not a valid daemon address; falling back to '
        '$defaultDaemonHost:$defaultDaemonPort';
    if (onDiagnostic != null) {
      deliverDiagnostic(onDiagnostic, 'daemon_address_invalid', message);
    } else {
      (writeLine ?? _writeStderr)('aws_xray_sdk: $message');
    }
  } catch (_) {/* never fault startup */}
}

/// Makes [raw] safe to echo on one line: URLs inside it are redacted first
/// (so a credential is never cut mid-way by the cap), control and format
/// characters (including line separators and bidi overrides) become spaces, and the result is capped at 100 UTF-16 code units without
/// splitting a surrogate pair.
String _sanitize(String raw) {
  final clean = redactUrlsInText(raw.trim())
      .replaceAll(RegExp(r'[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', unicode: true), ' ');
  if (clean.length <= 100) return clean;
  var end = 100;
  final last = clean.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return '${clean.substring(0, end)}...';
}

/// Writes [line] to stderr. A closed or broken stderr fails asynchronously
/// (on the sink's `done` future), so a plain try/catch would miss it and the
/// error would end the process; both paths are absorbed here.
void _writeStderr(String line) {
  runZonedGuarded(() {
    stderr.done.then<void>((_) {}, onError: (Object _) {});
    stderr.writeln(line);
  }, (_, __) {});
}
