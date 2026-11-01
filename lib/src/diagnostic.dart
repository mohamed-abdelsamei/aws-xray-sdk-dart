import 'dart:async';

/// A contained, non-segment failure or notable event reported through the
/// tracer's `onDiagnostic` hook.
///
/// Instances are created only by the SDK; read the fields, do not construct
/// one. [code] is a stable string (deliberately not an enum, so new codes can
/// be added in any release without breaking an exhaustive `switch`):
///
/// * `adapter_failed` - a user-supplied client adapter or hook threw and the
///   call carried on with less (or no) tracing data;
/// * `daemon_address_invalid` - `AWS_XRAY_DAEMON_ADDRESS` was set but could not
///   be parsed, so the default `127.0.0.1:2000` is used;
/// * `node_trimmed` - a single segment or subsegment was too large for one
///   UDP datagram even on its own, so its metadata was shortened (or it was
///   reduced to a bare node) before sending.
///
/// Send failures are not diagnostics; they go to `onSendError`.
final class XRayDiagnostic {
  XRayDiagnostic._(this.code, this.message, this.error, this.stackTrace);

  /// Stable machine-readable identifier, for example `node_trimmed`.
  final String code;

  /// Short human-readable sentence naming where it happened.
  final String message;

  /// The contained failure, when there is one.
  final Object? error;

  /// Stack trace of [error], when available.
  final StackTrace? stackTrace;

  @override
  String toString() => 'XRayDiagnostic($code: $message)';
}

/// Internal factory, hidden from the package barrel: the only way to build an
/// [XRayDiagnostic].
XRayDiagnostic createDiagnostic(
  String code,
  String message, {
  Object? error,
  StackTrace? stackTrace,
}) =>
    XRayDiagnostic._(code, message, error, stackTrace);

// True while an onDiagnostic hook is running, so a diagnostic raised from
// inside the hook (on the same call stack) is ignored instead of looping.
// Process-wide by design.
bool _inDiagnosticHook = false;

/// Internal, hidden from the package barrel: delivers a diagnostic to [hook]
/// (no-op when null). Never throws; a diagnostic raised while a hook is
/// already running is ignored.
void deliverDiagnostic(
  void Function(XRayDiagnostic diagnostic)? hook,
  String code,
  String message, {
  Object? error,
  StackTrace? stackTrace,
}) {
  if (hook == null || _inDiagnosticHook) return;
  _inDiagnosticHook = true;
  try {
    safeNotify(() => hook(
        createDiagnostic(code, message, error: error, stackTrace: stackTrace)));
  } finally {
    _inDiagnosticHook = false;
  }
}

/// Internal, hidden from the package barrel: runs an observability callback,
/// swallowing a synchronous throw and, if the callback returned a [Future]
/// despite the docs (an `async` closure), its late failure too, so a
/// misbehaving hook can never fault the traced operation or crash the process.
void safeNotify(Function notify) {
  try {
    final Object? result = notify();
    if (result is Future) result.then<void>((_) {}, onError: (_) {});
  } catch (_) {/* a hook must never break tracing */}
}
