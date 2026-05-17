import '../models/segment.dart';
import 'sender.dart';

/// Discards all segments. Use for testing or when sampling is 0.
final class NoopSender extends Sender {
  NoopSender();

  @override
  Future<void> send(Segment segment) async {}

  @override
  Future<void> close() async {}
}
