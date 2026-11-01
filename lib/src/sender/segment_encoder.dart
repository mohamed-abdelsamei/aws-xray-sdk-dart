import 'dart:convert';
import '../models/segment.dart';
import '../models/subsegment.dart';

/// Maximum size of a single UDP datagram payload sent to the X-Ray daemon.
///
/// The X-Ray segment-document limit is 64 KB, but a UDP datagram over IPv4
/// can carry at most 65507 bytes (65535 − 8 UDP header − 20 IP header), so
/// that is the real ceiling. Oversized segments are split into independent
/// subsegment documents.
const _maxUdpBytes = 65507;
const _header = '{"format":"json","version":1}';

/// Encodes a [Segment] into one or more UDP payloads, each ≤ 65507 bytes.
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

/// Encodes [sub] as one or more independent subsegment documents parented to
/// [parentId], splitting it the same way [encode] splits an oversized
/// segment's children so every datagram stays within the 65507-byte cap.
///
/// [json] overrides `sub.toJson()` for the root document only (e.g. with a
/// field removed); descendants always use their own `toJson()`.
List<List<int>> encodeSubsegmentDocs(
  Subsegment sub,
  String parentId,
  String traceId, {
  Map<String, Object?>? json,
}) {
  final out = <List<int>>[];
  _emitSubsegment(sub, parentId, traceId, out, json: json);
  return out;
}

/// Emits [sub] (and, if needed, its descendants) as independent subsegment
/// documents into [out], keeping each datagram within [_maxUdpBytes].
void _emitSubsegment(
  Subsegment sub,
  String parentId,
  String traceId,
  List<List<int>> out, {
  Map<String, Object?>? json,
}) {
  json ??= sub.toJson();
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
  final json = jsonEncode(doc, toEncodable: _fallbackEncodable);
  return utf8.encode('$_header\n$json');
}

/// Last-resort conversion for values `jsonEncode` cannot handle natively —
/// e.g. a `DateTime` or custom object in metadata, or a non-finite double.
///
/// Only invoked for values that would otherwise throw, so JSON-native
/// documents encode byte-for-byte as before. Tries `toJson()` (via a dynamic
/// call — no mirrors, AOT-safe), then `toString()`, then a fixed placeholder,
/// so one bad value never drops the whole segment.
Object? _fallbackEncodable(Object? value) {
  // Non-finite doubles (NaN, ±Infinity) have no toJson(); skip straight to
  // their string form ("NaN", "Infinity", "-Infinity").
  if (value is! num) {
    try {
      final Object? json = (value as dynamic).toJson();
      // jsonEncode does not re-apply toEncodable to this result's top level,
      // so only accept something it can write (nested values still fall back).
      if (json == null ||
          json is bool ||
          json is String ||
          (json is num && json.isFinite) ||
          json is List ||
          (json is Map && json.keys.every((k) => k is String))) {
        return json;
      }
    } catch (_) {
      // No toJson(), or it threw — fall through.
    }
  }
  try {
    return value.toString();
  } catch (_) {
    try {
      return '<unencodable:${value.runtimeType}>';
    } catch (_) {
      return '<unencodable>';
    }
  }
}
