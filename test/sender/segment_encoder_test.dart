import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

// ignore: implementation_imports — test needs direct access to encode()
import 'package:aws_xray_sdk/src/sender/segment_encoder.dart' as enc;

void main() {
  group('segment_encoder', () {
    Segment makeSegment() => Segment.begin(
          name: 'svc',
          traceId: TraceId.generate(),
        ).close();

    test('encode small segment returns one payload', () {
      final payloads = enc.encode(makeSegment());
      expect(payloads, hasLength(1));
    });

    test('payload starts with X-Ray header', () {
      final payload = enc.encode(makeSegment()).first;
      final text = utf8.decode(payload);
      expect(text, startsWith('{"format":"json","version":1}\n'));
    });

    test('payload is valid JSON after header', () {
      final payload = enc.encode(makeSegment()).first;
      final text = utf8.decode(payload);
      final body = text.substring(text.indexOf('\n') + 1);
      expect(() => jsonDecode(body), returnsNormally);
    });

    test('oversized segment splits into multiple payloads', () {
      // Build a segment with many subsegments to push it over 64 KB.
      var segment = Segment.begin(name: 'svc', traceId: TraceId.generate());
      for (var i = 0; i < 200; i++) {
        final sub = Subsegment.begin(name: 'op-$i', namespace: 'aws')
            .annotate('data', 'x' * 500)
            .close();
        segment = segment.addSubsegment(sub);
      }
      segment = segment.close();

      final payloads = enc.encode(segment);
      expect(payloads.length, greaterThan(1));
      for (final p in payloads) {
        expect(p.length, lessThanOrEqualTo(64 * 1024));
      }
    });
  });
}
