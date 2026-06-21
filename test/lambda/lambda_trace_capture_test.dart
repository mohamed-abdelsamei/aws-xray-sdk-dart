import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// A fake inner client that returns [_header] as the Lambda-Runtime-Trace-Id on
/// every response, mimicking the Runtime API /invocation/next call.
class _FakeRuntimeClient extends http.BaseClient {
  _FakeRuntimeClient(this._header);
  final String? _header;
  int sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    return http.StreamedResponse(
      Stream.value(utf8.encode('{}')),
      200,
      headers: {
        if (_header != null) 'lambda-runtime-trace-id': _header!,
        'content-type': 'application/json',
      },
    );
  }
}

void main() {
  group('LambdaTraceCapture', () {
    final traceId = TraceId.generate();
    final header = 'Root=$traceId;Parent=53995c3f42cd8ad8;Sampled=1';

    test('captures and parses the trace header from a response', () async {
      final fake = _FakeRuntimeClient(header);
      final capture = LambdaTraceCapture(innerFactory: () => fake);

      await capture.run(() async {
        // Simulate the runtime polling /invocation/next via the global client.
        await http.get(Uri.parse('http://localhost/invocation/next'));
      });

      expect(fake.sends, 1);
      expect(capture.rawHeader, header);

      final ctx = capture.context();
      expect(ctx.traceId.toString(), traceId.toString());
      expect(ctx.parentId, '53995c3f42cd8ad8');
      expect(ctx.sampled, isTrue);
    });

    test('Sampled=0 is parsed as not sampled', () async {
      final fake = _FakeRuntimeClient('Root=$traceId;Parent=abc123;Sampled=0');
      final capture = LambdaTraceCapture(innerFactory: () => fake);

      await capture.run(() async {
        await http.get(Uri.parse('http://localhost/invocation/next'));
      });

      expect(capture.context().sampled, isFalse);
    });

    test('no header captured yields a fresh trace and null parentId', () {
      // Without ever running a capture, context() must fail open to a fresh,
      // parentless trace so the caller starts a top-level segment.
      final capture =
          LambdaTraceCapture(innerFactory: () => _FakeRuntimeClient(null));

      final ctx = capture.context();
      expect(ctx.parentId, isNull);
      // A freshly generated id has the X-Ray shape 1-{8 hex}-{24 hex}.
      expect(ctx.traceId.toString(), matches(r'^1-[0-9a-f]{8}-[0-9a-f]{24}$'));
      expect(ctx.sampled, isTrue);
    });

    test('a response without the header leaves rawHeader empty', () async {
      final fake = _FakeRuntimeClient(null);
      final capture = LambdaTraceCapture(innerFactory: () => fake);

      await capture.run(() async {
        await http.get(Uri.parse('http://localhost/invocation/next'));
      });

      expect(capture.rawHeader, isEmpty);
      expect(capture.context().parentId, isNull);
    });

    test('the latest header wins across multiple invocations', () async {
      final t2 = TraceId.generate();
      var call = 0;
      final capture = LambdaTraceCapture(innerFactory: () {
        call++;
        return _FakeRuntimeClient(
          call == 1 ? header : 'Root=$t2;Parent=deadbeefdeadbeef;Sampled=1',
        );
      });

      // First invocation zone.
      await capture.run(() async {
        await http.get(Uri.parse('http://localhost/invocation/next'));
      });
      expect(capture.context().traceId.toString(), traceId.toString());

      // Second invocation zone (new client) overwrites the captured value.
      await capture.run(() async {
        await http.get(Uri.parse('http://localhost/invocation/next'));
      });
      expect(capture.context().traceId.toString(), t2.toString());
      expect(capture.context().parentId, 'deadbeefdeadbeef');
    });
  });
}
