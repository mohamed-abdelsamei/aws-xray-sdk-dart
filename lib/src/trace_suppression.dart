import 'dart:async';

// Zone key that suppresses the global `dart:io` HTTP patch ([XRayHttpClient])
// from opening subsegments for requests carried within the zone.
final _suppressDartIoKey = #_xraySuppressDartIo;

/// Runs [body] in a zone where the global `dart:io` HTTP patch installed by
/// `XRay.patchHttp` does **not** open subsegments.
///
/// Higher-level wrappers (`XRayBaseClient`, `XRay.fromClient`) call their inner
/// transport through this. When that transport ultimately uses a patched
/// `dart:io` `HttpClient`, the patch would otherwise trace the same request a
/// second time as a bare, host-named subsegment — producing a duplicate
/// alongside the wrapper's richer one. Suppressing the patch for the duration
/// of the inner send leaves exactly one subsegment (the wrapper's).
T runWithoutDartIoTracing<T>(T Function() body) =>
    runZoned(body, zoneValues: {_suppressDartIoKey: true});

/// Whether the current zone has suppressed the global `dart:io` HTTP patch.
bool get dartIoTracingSuppressed => Zone.current[_suppressDartIoKey] == true;
