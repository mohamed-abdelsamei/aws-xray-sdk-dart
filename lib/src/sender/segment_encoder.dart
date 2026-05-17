import 'dart:convert';
import '../models/segment.dart';

const _maxUdpBytes = 64 * 1024; // 64 KB
const _header = '{"format":"json","version":1}';

/// Encodes a [Segment] into one or more UDP payloads.
///
/// If the serialized segment is ≤ 64 KB it is returned as a single entry.
/// Otherwise the segment skeleton is returned first, followed by one entry
/// per subsegment sent as independent subsegment documents.
List<List<int>> encode(Segment segment) {
  // Serialise once and reuse the map for the split path.
  final json = segment.toJson();
  final bytes = _encodeOne(json);
  if (bytes.length <= _maxUdpBytes) return [bytes];

  // Segment is too large — send skeleton + individual subsegments.
  final skeleton = {...json}..remove('subsegments');
  final result = <List<int>>[_encodeOne(skeleton)];

  for (final sub in segment.subsegments) {
    final subDoc = {
      ...sub.toJson(),
      'type': 'subsegment',
      'parent_id': segment.id,
      'trace_id': segment.traceId.toString(),
    };
    result.add(_encodeOne(subDoc));
  }

  return result;
}

/// Encodes [subDoc] as an independent subsegment document, injecting the
/// required `"type":"subsegment"`, `"parent_id"`, and `"trace_id"` fields.
///
/// Use this when you need to attach spans to an existing segment that was
/// created outside the SDK (e.g. the `AWS::Lambda::Function` segment
/// auto-created by `provided:al2023`).
List<int> encodeSubsegmentDoc(
  Map<String, Object?> subDoc,
  String parentId,
  String traceId,
) =>
    _encodeOne({
      ...subDoc,
      'type': 'subsegment',
      'parent_id': parentId,
      'trace_id': traceId,
    });

List<int> _encodeOne(Map<String, Object?> doc) {
  final json = jsonEncode(doc);
  return utf8.encode('$_header\n$json');
}
