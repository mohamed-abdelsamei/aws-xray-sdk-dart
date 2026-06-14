import 'dart:convert';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

/// Golden baseline: locks the emitted JSON **structure** of `Segment` and
/// `Subsegment` so refactors cannot silently change the serialized document.
/// Compares decoded JSON deep-equality (not byte/key order), with the
/// non-deterministic `id` / `start_time` / `end_time` / `trace_id` values
/// normalized to a placeholder.
Object? _normalize(Object? node) {
  const volatile = {'id', 'start_time', 'end_time', 'trace_id'};
  if (node is Map) {
    return {
      for (final e in node.entries)
        e.key: volatile.contains(e.key) ? '<volatile>' : _normalize(e.value),
    };
  }
  if (node is List) return [for (final x in node) _normalize(x)];
  return node;
}

Object? _decoded(Map<String, Object?> json) =>
    _normalize(jsonDecode(jsonEncode(json)));

void main() {
  group('Segment/Subsegment golden JSON', () {
    test('Subsegment toJson — full shape with nested children', () {
      final faultChild =
          Subsegment.begin(name: 'child-500', namespace: 'remote')
              .applyStatus(500)
              .close();
      final throttleChild =
          Subsegment.begin(name: 'child-429', namespace: 'local')
              .applyStatus(429)
              .close();

      final sub = Subsegment.begin(name: 'db', namespace: 'aws')
          .withHttpCall(
            method: 'POST',
            url: 'https://dynamodb.us-east-1.amazonaws.com',
            status: 400,
            contentLength: 42,
          )
          .withAws(const AwsData(
            operation: 'PutItem',
            region: 'us-east-1',
            tableName: 'users',
          ))
          .withCause(const Cause(exceptions: [
            XRayException(id: 'e1', type: 'Boom', message: 'bad', remote: true),
          ]))
          .annotate('key', 'val')
          .addMetadata('mk', 'mv', namespace: 'ns')
          .addChild(faultChild)
          .addChild(throttleChild)
          .close();

      expect(
          _decoded(sub.toJson()),
          equals(<String, Object?>{
            'id': '<volatile>',
            'name': 'db',
            'namespace': 'aws',
            'start_time': '<volatile>',
            'end_time': '<volatile>',
            'error': true, // applyStatus(400)
            'cause': {
              'exceptions': [
                {
                  'id': '<volatile>',
                  'type': 'Boom',
                  'message': 'bad',
                  'remote': true
                },
              ],
            },
            'http': {
              'request': {
                'method': 'POST',
                'url': 'https://dynamodb.us-east-1.amazonaws.com',
              },
              'response': {'status': 400, 'content_length': 42},
            },
            'aws': {
              'operation': 'PutItem',
              'region': 'us-east-1',
              'table_name': 'users',
            },
            'annotations': {'key': 'val'},
            'metadata': {
              'ns': {'mk': 'mv'},
            },
            'subsegments': [
              {
                'id': '<volatile>',
                'name': 'child-500',
                'namespace': 'remote',
                'start_time': '<volatile>',
                'end_time': '<volatile>',
                'fault': true,
              },
              {
                'id': '<volatile>',
                'name': 'child-429',
                'namespace': 'local',
                'start_time': '<volatile>',
                'end_time': '<volatile>',
                'throttle': true,
                'error': true,
              },
            ],
          }));
    });

    test('Segment toJson — full shape with subsegment', () {
      final seg = Segment.begin(
        name: 'svc',
        traceId: TraceId.generate(),
        parentId: 'p1',
        user: 'u1',
        origin: 'AWS::EC2::Instance',
      )
          .withFault(const FormatException('boom'))
          .annotate('a', 1)
          .addMetadata('b', 2)
          .addSubsegment(
            Subsegment.begin(name: 'inner', namespace: 'local').close(),
          )
          .close();

      expect(
          _decoded(seg.toJson()),
          equals(<String, Object?>{
            'trace_id': '<volatile>',
            'id': '<volatile>',
            'name': 'svc',
            'start_time': '<volatile>',
            'end_time': '<volatile>',
            'parent_id': 'p1',
            'fault': true,
            'cause': {
              'exceptions': [
                {
                  'id': '<volatile>',
                  'type': 'FormatException',
                  'message': 'FormatException: boom',
                },
              ],
            },
            'annotations': {'a': 1},
            'metadata': {
              'default': {'b': 2},
            },
            'user': 'u1',
            'origin': 'AWS::EC2::Instance',
            'subsegments': [
              {
                'id': '<volatile>',
                'name': 'inner',
                'namespace': 'local',
                'start_time': '<volatile>',
                'end_time': '<volatile>',
              },
            ],
          }));
    });

    test('open entities emit in_progress and omit end_time', () {
      final sub = Subsegment.begin(name: 'open', namespace: 'local');
      final json = sub.toJson();
      expect(json['in_progress'], true);
      expect(json.containsKey('end_time'), isFalse);
    });
  });
}
