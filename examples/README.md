# X-Ray SDK Dart Examples

This directory contains comprehensive examples demonstrating how to use the `aws_xray_sdk_dart` package for distributed tracing.

## Examples Overview

### 1. [basic_usage.dart](basic_usage.dart)
Demonstrates fundamental X-Ray tracing concepts:
- Creating a tracer
- Generating trace IDs
- Creating and running segments
- Adding metadata and annotations

**Usage:**
```bash
dart run examples/basic_usage.dart
```

### 2. [http_tracing.dart](http_tracing.dart)
Shows automatic HTTP request tracing:
- Patching the global HTTP client
- Automatic subsegment creation for HTTP calls
- Response-based annotations
- Error handling for HTTP failures

**Usage:**
```bash
dart run examples/http_tracing.dart
```

### 3. [aws_sdk_tracing.dart](aws_sdk_tracing.dart)
Demonstrates AWS SDK client instrumentation:
- Wrapping Smithy-generated AWS clients
- Automatic subsegment creation for AWS operations
- Resource extraction (table names, etc.)
- Error handling for AWS API failures

**Usage:**
```bash
# Requires AWS credentials to be configured
dart run examples/aws_sdk_tracing.dart
```

### 4. [advanced_tracing.dart](advanced_tracing.dart)
Shows advanced tracing patterns:
- Manual subsegment creation
- Nested tracing with runSubsegment
- Multiple types of metadata and annotations
- File operations tracing
- Complex error handling scenarios

**Usage:**
```bash
dart run examples/advanced_tracing.dart
```

### 5. [sampling_strategies.dart](sampling_trategies.dart)
Demonstrates different sampling approaches:
- Fixed rate sampling
- Reservoir sampling
- Custom sampling strategies
- Sampling behavior visualization

**Usage:**
```bash
dart run examples/sampling_strategies.dart
```

### 6. [error_handling.dart](error_handling.dart)
Comprehensive error handling examples:
- HTTP status code handling (2xx, 4xx, 5xx)
- Exception handling and fault detection
- Throttled request handling (429)
- Nested operation error propagation
- Error metadata and cause tracking

**Usage:**
```bash
dart run examples/error_handling.dart
```

## Prerequisites

1. Install Dart SDK: https://dart.dev/get-dart
2. Ensure you have the X-Ray daemon running locally:
   ```bash
   # Install X-Ray daemon if not already installed
   brew install aws-xray-daemon
   
   # Start the daemon
   xray-daemon
   ```
   Or run in a container:
   ```bash
   docker run --rm -p 2000:2000 -p 2000:2000/udp amazon/aws-xray-daemon
   ```

## Common Setup

All examples use a similar pattern:

```dart
import 'package:aws_xray_sdk_dart/aws_xray_sdk_dart.dart';

void main() async {
  // Create tracer with sampling strategy
  final tracer = XRayTracer(
    serviceName: 'my-service',
    samplingStrategy: FixedRateSampler(rate: 1.0),
  );

  // Generate trace ID and create segment
  final traceId = TraceId.generate();
  final segment = Segment.begin(
    name: 'my-operation',
    traceId: traceId,
    serviceName: 'my-service',
  );

  // Run traced operation
  await tracer.run(segment, () async {
    // Your application code here
  });
}
```

## Configuration Options

### Tracer Configuration
```dart
final tracer = XRayTracer(
  serviceName: 'my-service',
  samplingStrategy: FixedRateSampler(rate: 0.1), // 10% sampling
  daemonAddress: 'localhost:2000', // Default
  useHttp: false, // Use UDP instead of HTTP
);
```

### Sampling Strategies
- **FixedRateSampler**: Sample at a fixed rate (0.0 to 1.0)
- **ReservoirSampler**: Keep a fixed number of samples per time interval
- **Custom**: Implement your own `SamplingStrategy`

### Metadata and Annotations
```dart
// Add metadata (appears in X-Ray console)
segment.addMetadata('key', 'value');

// Add annotations (searchable fields)
segment.addAnnotation('http.status', 200);
```

## Integration Patterns

### 1. Web Server Integration
```dart
// In your web server setup
XRay.patchHttp(tracer);

// Handle each request
final segment = Segment.begin(
  name: 'http-request',
  traceId: request.headers['X-Amzn-Trace-Id'],
  serviceName: 'web-server',
);

await tracer.run(segment, () {
  return handleRequest(request, response);
});
```

### 2. Database Operations
```dart
await tracer.runSubsegment(segment, 'database-query', () async {
  // Database code here
  await db.query('SELECT * FROM users');
});
```

### 3. External Service Calls
```dart
final client = XRay.fromClient(HttpClient(), tracer: tracer);
await client.get(Uri.parse('https://api.example.com/data'));
```

## Troubleshooting

### X-Ray Daemon Not Found
If you see connection errors, ensure the X-Ray daemon is running:
```bash
# Check if daemon is running
lsof -i :2000

# Start daemon if needed
xray-daemon
```

### Sampling Issues
- Use `FixedRateSampler(rate: 1.0)` for development to ensure all traces are captured
- Check your sampling strategy implementation for production use

### Missing Segments
- Verify the daemon is running and accessible
- Check network connectivity to the daemon
- Enable debug logging to see trace data

## Best Practices

1. **Use descriptive segment names** that reflect the operation
2. **Add relevant metadata** for debugging and monitoring
3. **Implement proper sampling** for production environments
4. **Handle errors gracefully** with appropriate fault flags
5. **Keep segments focused** - break down complex operations into subsegments
6. **Use annotations for searchable data** (HTTP status, user IDs, etc.)

## Viewing Traces

After running examples, you can view traces in the AWS X-Ray console:
1. Go to AWS X-Ray Console
2. Click "Trace map" or "Traces"
3. Search for your service name or trace ID
4. Explore the trace details and subsegments