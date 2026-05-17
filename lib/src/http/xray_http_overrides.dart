import 'dart:io';
import '../tracer.dart';
import 'xray_http_client.dart';

/// [HttpOverrides] implementation that wraps every new [HttpClient] with
/// [XRayHttpClient] so all `dart:io` HTTP calls are automatically traced.
///
/// Install globally via [XRay.patchHttp] or directly:
/// ```dart
/// HttpOverrides.global = XRayHttpOverrides(tracer);
/// ```
final class XRayHttpOverrides extends HttpOverrides {
  XRayHttpOverrides(this._tracer, [this.previous]);

  final XRayTracer _tracer;

  /// Previous overrides that are restored when [XRay.unpatchHttp] is called.
  final HttpOverrides? previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = previous != null
        ? previous!.createHttpClient(context)
        : super.createHttpClient(context);
    return XRayHttpClient(inner, _tracer);
  }
}
