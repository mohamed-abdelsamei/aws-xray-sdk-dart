import '../models/segment.dart';
import 'sender.dart';

/// A [Sender] that records everything it is given instead of transmitting it.
///
/// Intended for tests: build a tracer with an `InMemorySender`, exercise the
/// code under test, then assert on what was emitted — without opening a UDP
/// socket or mocking the tracer.
///
/// ```dart
/// final sender = InMemorySender();
/// final tracer = XRayTracer(serviceName: 'svc', sender: sender);
/// await tracer.run(Segment.begin(name: 'svc', traceId: TraceId.generate()),
///     () async { /* ... */ });
/// expect(sender.segments, hasLength(1));
/// expect(sender.segments.single.subsegments, hasLength(1));
/// ```
///
/// Both delivery paths are captured: closed [Segment]s arrive in [segments]
/// (the normal path), and pre-encoded UDP payloads — e.g. the independent
/// subsegment documents emitted by `XRayTracer.runLambda` — arrive in
/// [packets].
final class InMemorySender extends Sender {
  final List<Segment> _segments = [];
  final List<List<int>> _packets = [];

  /// Segments captured via [send], in the order received.
  List<Segment> get segments => List.unmodifiable(_segments);

  /// Raw payloads captured via [sendPackets], in the order received.
  List<List<int>> get packets => List.unmodifiable(_packets);

  /// Whether [close] has been called.
  bool get isClosed => _closed;
  bool _closed = false;

  /// Removes all captured segments and packets and reopens the sender.
  void clear() {
    _segments.clear();
    _packets.clear();
    _closed = false;
  }

  @override
  Future<void> send(Segment segment) async => _segments.add(segment);

  @override
  Future<void> sendPackets(List<List<int>> packets) async =>
      _packets.addAll(packets);

  @override
  Future<void> close() async => _closed = true;
}
