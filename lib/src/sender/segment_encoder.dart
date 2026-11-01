import 'dart:async';
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

/// Zone key under which a caller may install a
/// `void Function(String name, int replaced, bool bare)` to be told when a node
/// is trimmed (see [encode]). Internal; not part of the public API. This key is
/// the contract between this file and `tracer.dart`: the tracer installs the
/// callback, the encoder calls it. The callback is looked up in the zone that
/// is current when the encoder runs, so an encode done outside the send call
/// reports nothing.
final trimReportKey = #_xrayTrimReport;

void _reportTrim(Object? name, int replaced, bool bare) {
  final report = Zone.current[trimReportKey];
  if (report is! void Function(String, int, bool)) return;
  try {
    report(_capName(name), replaced, bare);
  } catch (_) {/* reporting must never break encoding */}
}

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
/// A single node (a leaf subsegment, or a skeleton whose own payload is still
/// too big) cannot be split further, so it is trimmed to fit instead: the
/// largest `metadata` values are replaced with a `[truncated: N bytes]` marker
/// (just enough of them), and `metadata.xray.truncated` is set to `true`. If
/// that is not enough, the node is reduced to its small structural fields
/// (ids, times, status flags, a shortened `name`) plus the marker. The
/// in-memory model is never changed, and a node that already fits is emitted
/// byte for byte as before. This guarantees the datagram fits the cap; it does
/// not guarantee the service accepts the trimmed document.
List<List<int>> encode(Segment segment) {
  // Serialise once and reuse the map for the split path.
  final json = segment.toJson();
  final bytes = _encodeOne(json);
  if (bytes.length <= _maxUdpBytes) return [bytes];

  // Segment is too large — send skeleton + individual subsegment documents.
  final skeleton = {...json}..remove('subsegments');
  final result = <List<int>>[_fitNode(skeleton)];
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
/// documents into [out], keeping each datagram within [_maxUdpBytes] (a node
/// that is too big even on its own is trimmed, see [encode]).
void _emitSubsegment(
  Subsegment sub,
  String parentId,
  String traceId,
  List<List<int>> out, {
  Map<String, Object?>? json,
}) {
  json ??= sub.toJson();
  final envelope = _envelope(parentId, traceId);
  final doc = encodeSubsegmentDoc(json, parentId, traceId);
  if (doc.length <= _maxUdpBytes) {
    out.add(doc);
    return;
  }
  if (sub.subsegments.isEmpty) {
    // A leaf cannot be split further — trim it to fit.
    out.add(_fitNode(json, envelope, doc));
    return;
  }

  // Too large with children inlined: emit this node without its children
  // (trimmed if it is still too big), then re-parent each child to it as its
  // own document (recursing as needed).
  final skeleton = {...json}..remove('subsegments');
  out.add(_fitNode(skeleton, envelope));
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
    _encodeOne({...subDoc, ..._envelope(parentId, traceId)});

Map<String, Object?> _envelope(String parentId, String traceId) => {
      'type': 'subsegment',
      'parent_id': parentId,
      'trace_id': traceId,
    };

const _truncatedKey = 'truncated';
const _nameCap = 200;

// Small, bounded fields kept when a node has to be reduced to its structure.
const _structuralKeys = [
  'trace_id',
  'id',
  'parent_id',
  'type',
  'start_time',
  'end_time',
  'in_progress',
  'fault',
  'error',
  'throttle',
];

/// Encodes [node] (plus [envelope], the fields an independent subsegment
/// document adds) so the datagram is at most [_maxUdpBytes]. Called only for a
/// node that cannot be split further; [node] is a `toJson()` copy and is never
/// modified.
List<int> _fitNode(
  Map<String, Object?> node, [
  Map<String, Object?> envelope = const {},
  List<int>? encoded,
]) {
  final whole = encoded ?? _encodeOne({...node, ...envelope});
  if (whole.length <= _maxUdpBytes) return whole;

  // First trim metadata: replace the largest values with a marker, as few as fit.
  final metadata = node['metadata'];
  if (metadata is Map) {
    final candidates = <_Replaceable>[];
    metadata.forEach((ns, values) {
      if (ns is! String || values is! Map) return;
      values.forEach((key, value) {
        if (key is! String) return;
        final size = _valueBytes(value).length;
        final marker = _marker(size);
        // Replacing a value no longer than its marker would grow the document.
        if (_valueBytes(marker).length < size) {
          candidates.add(_Replaceable(ns, key, size, marker));
        }
      });
    });
    // Largest first; the sort is stable on ties because of the index.
    final indexed = [for (var i = 0; i < candidates.length; i++) i];
    indexed.sort((a, b) {
      final bySize = candidates[b].size.compareTo(candidates[a].size);
      return bySize != 0 ? bySize : a.compareTo(b);
    });
    final ordered = [for (final i in indexed) candidates[i]];

    List<int> attempt(int count) => _encodeOne({
          ...node,
          'metadata': _trimMetadata(metadata, ordered.take(count)),
          ...envelope,
        });

    if (ordered.isNotEmpty && attempt(ordered.length).length <= _maxUdpBytes) {
      // Smallest sufficient count (size only shrinks as more are replaced).
      var lo = 1, hi = ordered.length;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        if (attempt(mid).length <= _maxUdpBytes) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      _reportTrim(node['name'], lo, false);
      return attempt(lo);
    }
  }

  // Still too big: reduce to a bare node. Only small structural fields survive.
  final bare = <String, Object?>{
    for (final k in _structuralKeys)
      if (node.containsKey(k)) k: node[k],
  };
  _reportTrim(node['name'], 0, true);
  bare['name'] = _capName(node['name']);
  final ns = node['namespace'];
  if (ns == 'aws' || ns == 'remote') bare['namespace'] = ns;
  bare['metadata'] = {
    'xray': {_truncatedKey: true},
  };
  return _encodeOne({...bare, ...envelope});
}

class _Replaceable {
  _Replaceable(this.namespace, this.key, this.size, this.marker);
  final String namespace;
  final String key;
  final int size;
  final String marker;
}

String _marker(int bytes) => '[truncated: $bytes bytes]';

/// Encoded size of one value as it will be written (including the
/// `toEncodable` fallback for values that are not JSON-native).
List<int> _valueBytes(Object? value) =>
    utf8.encode(jsonEncode(value, toEncodable: _fallbackEncodable));

/// A copy of [metadata] with [replaced] swapped for their markers and
/// `xray.truncated` set; every other value and key keeps its place.
Map<String, Object?> _trimMetadata(
  Map<dynamic, dynamic> metadata,
  Iterable<_Replaceable> replaced,
) {
  final byNs = <String, Map<String, String>>{};
  for (final r in replaced) {
    (byNs[r.namespace] ??= {})[r.key] = r.marker;
  }
  final out = <String, Object?>{};
  metadata.forEach((ns, values) {
    if (ns is! String) return;
    final swap = byNs[ns];
    out[ns] = swap == null || values is! Map
        ? values
        : {
            for (final e in values.entries)
              e.key: swap.containsKey(e.key) ? swap[e.key] : e.value,
          };
  });
  final xray = out['xray'];
  out['xray'] = {
    if (xray is Map) ...xray,
    _truncatedKey: true,
  };
  return out;
}

/// [name] cut to [_nameCap] UTF-16 code units, never inside a surrogate pair.
String _capName(Object? name) {
  final s = name is String ? name : '';
  if (s.length <= _nameCap) return s;
  var end = _nameCap;
  final last = s.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return s.substring(0, end);
}

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
