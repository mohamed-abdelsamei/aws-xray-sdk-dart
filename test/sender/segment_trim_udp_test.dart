// A trimmed node must actually be accepted by UdpSender: the injected socket
// refuses (returns 0 for) any datagram over the IPv4 limit, the way the OS
// does. No real socket is opened.
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

class _LimitedSocket implements RawDatagramSocket {
  final accepted = <List<int>>[];
  int refused = 0;

  @override
  int send(List<int> buffer, InternetAddress address, int port) {
    if (buffer.length > 65507) {
      refused++;
      return 0;
    }
    accepted.add(buffer);
    return buffer.length;
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _LimitedSocket socket;
  late List<Object> senderErrors;
  late List<Object> sendErrors;
  late XRayTracer tracer;

  setUp(() {
    socket = _LimitedSocket();
    senderErrors = [];
    sendErrors = [];
    tracer = XRayTracer(
      serviceName: 'svc',
      sampling: FixedRateSampler(1.0),
      sender: UdpSender(
        onError: senderErrors.add,
        socketFactory: (_) async => socket,
      ),
      onSendError: (s, e) => sendErrors.add(e),
    );
  });

  test('a standalone trace with a 70 KB metadata value is fully accepted',
      () async {
    await tracer.run(
      Segment.begin(name: 'svc', traceId: TraceId.generate()),
      () async {
        final sub = tracer.beginSubsegment('op');
        tracer.addMetadata('body', 'x' * 70000);
        tracer.endSubsegment(sub);
      },
    );
    expect(socket.refused, 0);
    expect(socket.accepted, isNotEmpty);
    expect(senderErrors, isEmpty);
    expect(sendErrors, isEmpty);
  });

  test('a Lambda handler with a 70 KB metadata value is fully accepted',
      () async {
    await tracer.runLambda(
      TraceId.generate(),
      'abcdef1234567890',
      'handler',
      () async => tracer.addMetadata('body', 'x' * 70000),
    );
    expect(socket.refused, 0);
    expect(socket.accepted, isNotEmpty);
    expect(senderErrors, isEmpty);
    expect(sendErrors, isEmpty);
  });
}
