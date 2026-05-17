import '../models/segment.dart';

/// Transport abstraction for delivering completed segments to X-Ray.
abstract class Sender {
  Future<void> send(Segment segment);
  Future<void> close();

  /// Sends pre-encoded UDP payloads directly to the X-Ray daemon.
  ///
  /// Used by [XRayTracer.runLambda] to deliver independent subsegment
  /// documents without going through the normal [Segment] serialization path.
  ///
  /// The default implementation is a no-op; override in transport subclasses
  /// that support raw packet delivery (e.g. [UdpSender]).
  Future<void> sendPackets(List<List<int>> packets) async {}
}
