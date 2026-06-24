import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

// ignore: implementation_imports — buildTraceHeader is internal.
import 'package:aws_xray_sdk/src/trace_header.dart';

void main() {
  group('buildTraceHeader', () {
    test('builds a valid header and roundtrips through the parser', () {
      final traceId = TraceId.generate().toString();
      const segmentId = '0123456789abcdef';
      final header = buildTraceHeader(
        traceId: traceId,
        segmentId: segmentId,
        sampled: true,
      );

      expect(header, 'Root=$traceId;Parent=$segmentId;Sampled=1');
      // Symmetric with the parser.
      expect(TraceId.parseRootString(header), traceId);
      expect(TraceId.parseParentId(header), segmentId);
      expect(TraceId.parseSampled(header), isTrue);
    });

    test('encodes Sampled=0 when not sampled', () {
      final header = buildTraceHeader(
        traceId: TraceId.generate().toString(),
        segmentId: '0123456789abcdef',
        sampled: false,
      );
      expect(header, endsWith(';Sampled=0'));
    });

    test('asserts on a malformed trace id (debug only)', () {
      expect(
        () => buildTraceHeader(
            traceId: 'not-a-trace',
            segmentId: '0123456789abcdef',
            sampled: true),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => buildTraceHeader(
            traceId: '2-abc-def', segmentId: '0123456789abcdef', sampled: true),
        throwsA(isA<AssertionError>()),
      );
    });

    test('asserts on a malformed segment id (debug only)', () {
      final traceId = TraceId.generate().toString();
      expect(
        () => buildTraceHeader(
            traceId: traceId, segmentId: 'short', sampled: true),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => buildTraceHeader(
            traceId: traceId, segmentId: 'g123456789abcdef', sampled: true),
        throwsA(isA<AssertionError>()),
        reason: 'non-hex characters are rejected',
      );
    });
  });
}
