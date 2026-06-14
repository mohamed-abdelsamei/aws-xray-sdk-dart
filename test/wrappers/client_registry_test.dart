import 'package:aws_xray_sdk/aws_xray_sdk.dart';
// ignore: implementation_imports
import 'package:aws_xray_sdk/src/wrappers/client_registry.dart';
import 'package:test/test.dart';

// A minimal stub client type for registry tests.
class _StubClient {
  const _StubClient(this.id);
  final String id;
}

// Minimal no-op adapters for test registrations.
SmithyRequestAdapter<Object> _noopRequestAdapter(Object req) => (
      operationName: 'Test',
      method: 'POST',
      url: 'https://example.com',
      body: const {},
      withTraceHeader: (r, h) => r,
    );

SmithyResponseAdapter<Object> _noopResponseAdapter(Object res) => (
      statusCode: 200,
      contentLength: null,
      requestId: null,
      region: null,
      errorCode: null,
    );

void main() {
  group('ClientRegistry', () {
    tearDown(() {
      // Clean up registrations added during tests.
      clientRegistry.remove(_StubClient);
    });

    test('registerClient stores a descriptor for the type', () {
      XRay.registerClient<_StubClient>(
        namespace: 'AWS::Stub',
        requestAdapter: _noopRequestAdapter,
        responseAdapter: _noopResponseAdapter,
        rebuild: (original, _) => original,
      );

      final desc = descriptorFor<_StubClient>();
      expect(desc, isNotNull);
      expect(desc!.namespace, 'aws');
    });

    test('descriptorFor returns null for unregistered type', () {
      expect(descriptorFor<_StubClient>(), isNull);
    });

    test('fromClient throws StateError for unregistered type', () {
      final tracer = XRayTracer(
        serviceName: 'svc',
        sender: NoopSender(),
        sampling: FixedRateSampler(1.0),
      );
      expect(
        () => XRay.fromClient(const _StubClient('y'), tracer: tracer),
        throwsA(isA<StateError>()),
      );
    });

    test('fromClient calls rebuild and returns new client', () {
      _StubClient? rebuildReceived;
      XRay.registerClient<_StubClient>(
        namespace: 'AWS::Stub',
        requestAdapter: _noopRequestAdapter,
        responseAdapter: _noopResponseAdapter,
        rebuild: (original, wrapSend) {
          rebuildReceived = original;
          return _StubClient('wrapped-${original.id}');
        },
      );

      final tracer = XRayTracer(
        serviceName: 'svc',
        sender: NoopSender(),
        sampling: FixedRateSampler(1.0),
      );
      final original = const _StubClient('original');
      final wrapped = XRay.fromClient(original, tracer: tracer);

      expect(rebuildReceived?.id, 'original');
      expect(wrapped.id, 'wrapped-original');
    });

    test('registering the same type twice overwrites the descriptor', () {
      XRay.registerClient<_StubClient>(
        namespace: 'AWS::First',
        requestAdapter: _noopRequestAdapter,
        responseAdapter: _noopResponseAdapter,
        rebuild: (o, _) => o,
      );
      XRay.registerClient<_StubClient>(
        namespace: 'AWS::Second',
        requestAdapter: _noopRequestAdapter,
        responseAdapter: _noopResponseAdapter,
        rebuild: (o, _) => o,
      );

      final desc = descriptorFor<_StubClient>();
      expect(desc!.namespace, 'aws');
    });

    test('custom non-AWS namespace normalizes to remote', () {
      XRay.registerClient<_StubClient>(
        namespace: 'custom',
        requestAdapter: _noopRequestAdapter,
        responseAdapter: _noopResponseAdapter,
        rebuild: (o, _) => o,
      );

      final desc = descriptorFor<_StubClient>();
      expect(desc!.namespace, 'remote');
    });
  });
}
