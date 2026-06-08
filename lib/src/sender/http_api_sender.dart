import '../models/segment.dart';
import 'sender.dart';

/// Sends segments via the X-Ray `PutTraceSegments` HTTP API.
///
/// **⚠️ Not yet implemented.** SigV4 request signing is not in place, so [send]
/// throws [UnimplementedError]. Use [UdpSender] (the default) for all
/// deployments. Not exported from the package barrel until SigV4 lands.
final class HttpApiSender extends Sender {
  HttpApiSender({required this.region});

  final String region;

  @override
  Future<void> send(Segment segment) => throw UnimplementedError(
        'HttpApiSender requires SigV4 request signing, which is not yet '
        'implemented. Use UdpSender (the default) instead.',
      );

  @override
  Future<void> close() async {}
}
