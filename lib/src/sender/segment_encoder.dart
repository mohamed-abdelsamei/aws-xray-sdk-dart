import 'dart:convert';
import '../models/segment.dart';
import '../models/subsegment.dart';

/// Maximum size of a single segment document the X-Ray daemon accepts over UDP.
/// Per the X-Ray API guide, the segment-document limit is 64 KB; oversized
/// segments must be split into independent subsegment documents.
const _maxUdpBytes = 64 * 1024; // 64 KB
const _header = '{"format":"json","version":1}';

/// Encodes a [Segment] into one or more UDP payloads, each ≤ 64 KB.
///
/// If the serialized segment fits in one datagram it is returned as a single
/// entry. Otherwise the segment skeleton (no `subsegments`) is emitted first,
/// followed by each subsegment as an independent subsegment document
/// (`type:subsegment`, `parent_id`, `trace_id`). A subsegment whose own
/// document still exceeds the cap is split recursively: it is emitted without
/// its children, and each child is emitted as a separate document parented to
/// it — so the tree is preserved while every datagram stays within the limit.
///
/// A single leaf subsegment larger than the cap cannot be split further; it is
/// emitted as-is (the daemon may reject it) rather than dropped, so the failure
/// is at least visible.
List<List<int>> encode(Segment segment) {
  // Serialise once and reuse the map for the split path.
  final json = segment.toJson();
  final bytes = _encodeOne(json);
  if (bytes.length <= _maxUdpBytes) return [bytes];

  // Segment is too large — send skeleton + individual subsegment documents.
  final skeleton = {...json}..remove('subsegments');
  final result = <List<int>>[_encodeOne(skeleton)];
  final traceId = segment.traceId.toString();

  for (final sub in segment.subsegments) {
    _emitSubsegment(sub, segment.id, traceId, result);
  }

  return result;
}

/// Emits [sub] (and, if needed, its descendants) as independent subsegment
/// documents into [out], keeping each datagram within [_maxUdpBytes].
void _emitSubsegment(
  Subsegment sub,
  String parentId,
  String traceId,
  List<List<int>> out,
) {
  final json = sub.toJson();
  final doc = encodeSubsegmentDoc(json, parentId, traceId);
  if (doc.length <= _maxUdpBytes || sub.subsegments.isEmpty) {
    // Fits, or is a leaf we cannot split further — emit as-is.
    out.add(doc);
    return;
  }

  // Too large with children inlined: emit this node without its children, then
  // re-parent each child to it as its own document (recursing as needed).
  final skeleton = {...json}..remove('subsegments');
  out.add(encodeSubsegmentDoc(skeleton, parentId, traceId));
  for (final child in sub.subsegments) {
    _emitSubsegment(child, sub.id, traceId, out);
  }
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
