import 'dart:async';

import 'package:http/http.dart' as http;

import '../models/trace_id.dart';

/// Parsed X-Ray trace context for a single Lambda invocation, taken from the
/// `Lambda-Runtime-Trace-Id` header of the Runtime API `/invocation/next`
/// response.
///
/// [parentId] is the id of Lambda's auto-created `AWS::Lambda::Function`
/// segment. When it is non-null, pass these fields to
/// [XRayTracer.runLambda] so the handler span is parented under that facade
/// segment. When it is null (no trace header captured yet), the only correct
/// choice is a fresh top-level segment via [XRayTracer.run] — see
/// [LambdaTraceCapture.context].
final class LambdaTraceContext {
  const LambdaTraceContext({
    required this.traceId,
    required this.parentId,
    required this.sampled,
  });

  final TraceId traceId;
  final String? parentId;
  final bool sampled;
}

/// Captures the `Lambda-Runtime-Trace-Id` header that the AWS Lambda Runtime
/// API returns on each `/invocation/next` call — the authoritative trace id
/// Lambda assigns to its auto-created `AWS::Lambda::Function` segment.
///
/// This is the trace context every official X-Ray runtime reads for you. In
/// Dart, community runtimes (e.g. `aws_lambda_dart_runtime_ns`) consume that
/// response with the global `package:http` client and do not surface the
/// header, so we re-capture it by overriding that global client for a zone
/// with [http.runWithClient].
///
/// **Do not** use the `_X_AMZN_TRACE_ID` environment variable instead: it
/// carries the *incoming request's* trace, not Lambda's function-level trace,
/// so it breaks parent→child linkage and orphans subsegments in a separate
/// trace.
///
/// Usage (with any runtime that drives invocations through `package:http`):
///
/// ```dart
/// final capture = LambdaTraceCapture();
/// await capture.run(() => invokeAwsLambdaRuntime([
///   // inside each handler:
///   //   final ctx = capture.context();
///   //   if (ctx.parentId != null) {
///   //     return tracer.runLambda(ctx.traceId, ctx.parentId!,
///   //         runtimeCtx.functionName, fn, sampled: ctx.sampled);
///   //   }
///   //   return tracer.run(
///   //       Segment.begin(name: runtimeCtx.functionName, traceId: ctx.traceId,
///   //           origin: 'AWS::Lambda::Function'), fn);
/// ]));
/// ```
///
/// The runtime-specific handler glue (reading `functionName`, dispatching the
/// action) is intentionally left to the caller, since it depends on the chosen
/// runtime package; this class only owns the trace-header capture and parsing.
///
/// **Sequential safety:** a Lambda sandbox processes one invocation at a time.
/// The header is written when the runtime polls `/invocation/next` and read by
/// the handler before the next poll, so there is no interleaving within a
/// single sandbox. Use one [LambdaTraceCapture] per runtime loop; it is not
/// designed for concurrent invocations sharing an instance.
final class LambdaTraceCapture {
  LambdaTraceCapture({http.Client Function()? innerFactory})
      : _innerFactory = innerFactory ?? http.Client.new;

  final http.Client Function() _innerFactory;

  // The most recently captured raw header value. Empty until the first
  // /invocation/next response carrying the header is seen.
  String _rawHeader = '';

  /// The raw `Lambda-Runtime-Trace-Id` header last seen, or an empty string if
  /// none has been captured yet.
  String get rawHeader => _rawHeader;

  /// Runs [fn] (typically the runtime's invocation loop) inside a zone whose
  /// global `package:http` client captures the trace header from every
  /// response. Returns whatever [fn] returns.
  Future<T> run<T>(Future<T> Function() fn) =>
      http.runWithClient(fn, () => _CapturingClient(_innerFactory(), this));

  /// The parsed trace context for the current invocation, derived from the most
  /// recently captured header.
  ///
  /// When no header has been captured, [LambdaTraceContext.parentId] is null
  /// and [LambdaTraceContext.traceId] is freshly generated — the caller should
  /// then start a fresh top-level segment rather than call `runLambda`.
  LambdaTraceContext context() => LambdaTraceContext(
        traceId: TraceId.tryParse(_rawHeader) ?? TraceId.generate(),
        parentId: TraceId.parseParentId(_rawHeader),
        sampled: TraceId.parseSampled(_rawHeader) ?? true,
      );

  void _capture(String? header) {
    if (header != null && header.isNotEmpty) _rawHeader = header;
  }
}

/// Wraps an inner [http.Client], sniffing the `lambda-runtime-trace-id`
/// response header into the owning [LambdaTraceCapture] and otherwise passing
/// the call through unchanged.
class _CapturingClient extends http.BaseClient {
  _CapturingClient(this._inner, this._owner);

  final http.Client _inner;
  final LambdaTraceCapture _owner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    _owner._capture(response.headers['lambda-runtime-trace-id']);
    return response;
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
