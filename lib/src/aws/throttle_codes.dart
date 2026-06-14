/// Returns whether [code] is a known AWS throttling error code.
///
/// AWS services often report throttles as HTTP 400 responses with a modeled
/// error code instead of HTTP 429.
bool isThrottleErrorCode(String code) {
  final normalized = code.split('#').last.split(':').first;
  return throttleErrorCodes.contains(normalized);
}

const throttleErrorCodes = {
  'Throttling',
  'ThrottlingException',
  'ThrottledException',
  'RequestThrottledException',
  'TooManyRequestsException',
  'TooManyRequests',
  'ProvisionedThroughputExceededException',
  'RequestLimitExceeded',
  'LimitExceededException',
  'SlowDown',
};
