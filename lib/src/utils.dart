import 'dart:math';

final _rng = Random.secure();

/// Returns a [length]-character lowercase hexadecimal string using
/// a cryptographically secure random number generator.
String randomHex(int length) {
  final buf = StringBuffer();
  for (var i = 0; i < length; i++) {
    buf.write(_rng.nextInt(16).toRadixString(16));
  }
  return buf.toString();
}

/// Returns the current time as seconds since the Unix epoch (floating-point).
double nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000.0;

/// Host suffix identifying an AWS endpoint (e.g.
/// `dynamodb.us-east-1.amazonaws.com`). Shared by the `dart:io` and
/// `package:http` clients for AWS host detection.
const awsDomainSuffix = '.amazonaws.com';
