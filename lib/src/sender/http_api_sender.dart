import 'dart:io';
import '../models/segment.dart';
import 'sender.dart';

/// Sends segments via the X-Ray PutTraceSegments HTTP API.
///
/// **⚠️ Not yet usable in production.** SigV4 request signing has not been
/// implemented. Every call to [send] will throw [UnimplementedError] until
/// SigV4 is in place. Use [UdpSender] for all current deployments.
///
/// [region] is required. Credentials are read from [accessKeyId] /
/// [secretAccessKey] constructor arguments, falling back to the
/// `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` environment variables.
///
/// Throws [ArgumentError] at construction time when no credentials can be
/// resolved, to surface misconfiguration early.
final class HttpApiSender extends Sender {
  HttpApiSender({
    required this.region,
    String? accessKeyId,
    String? secretAccessKey,
    String? endpoint,
  })  : _accessKeyId =
            accessKeyId ?? Platform.environment['AWS_ACCESS_KEY_ID'] ?? '',
        _secretAccessKey = secretAccessKey ??
            Platform.environment['AWS_SECRET_ACCESS_KEY'] ??
            '',
        _endpoint =
            endpoint ?? 'https://xray.$region.amazonaws.com/TraceSegments' {
    if (_accessKeyId.isEmpty || _secretAccessKey.isEmpty) {
      throw ArgumentError(
        'HttpApiSender: AWS credentials are required. '
        'Provide accessKeyId and secretAccessKey, or set the '
        'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables.',
      );
    }
  }

  final String region;
  final String _accessKeyId;
  final String _secretAccessKey;
  final String _endpoint;

  @override
  Future<void> send(Segment segment) {
    // ignore: avoid_print — surface the error loudly until SigV4 is implemented
    throw UnimplementedError(
      'HttpApiSender.send() requires SigV4 request signing which is not yet '
      'implemented. Use UdpSender (the default) instead. '
      'Credentials held: accessKeyId=${_accessKeyId.isNotEmpty}, '
      'endpoint=$_endpoint',
    );
  }

  @override
  Future<void> close() async {
    // No-op: no persistent connections while send() is unimplemented.
  }
}
