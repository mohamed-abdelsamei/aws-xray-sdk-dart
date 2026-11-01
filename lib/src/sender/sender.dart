import '../models/segment.dart';

/// Transport abstraction for delivering completed segments to X-Ray.
///
/// To implement a custom sender, extend this class and override [send] and
/// [close]. Also override [sendPackets] if the sender is used with
/// [XRayTracer.runLambda]: the Lambda path delivers pre-encoded subsegment
/// documents through [sendPackets] only, and the default implementation
/// throws [UnsupportedError].
abstract class Sender {
  Future<void> send(Segment segment);
  Future<void> close();

  /// Sends pre-encoded UDP payloads directly to the X-Ray daemon.
  ///
  /// Used by [XRayTracer.runLambda] to deliver independent subsegment
  /// documents without going through the normal [Segment] serialization path.
  ///
  /// The default implementation throws [UnsupportedError], so a sender that
  /// does not override it fails loudly (when `onSendError` is set) instead of
  /// silently dropping every Lambda trace. The tracer catches the error and
  /// reports it through `onSendError`; it never reaches the application. Built-in senders
  /// ([UdpSender], `InMemorySender`, `NoopSender`) override it.
  Future<void> sendPackets(List<List<int>> packets) async {
    throw UnsupportedError(
      '$runtimeType does not implement sendPackets(); '
      'XRayTracer.runLambda needs sendPackets to deliver Lambda traces. '
      'Override sendPackets in $runtimeType.',
    );
  }
}
