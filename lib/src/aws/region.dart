/// Derives an AWS region from standard regional AWS endpoint hosts.
///
/// Example: `dynamodb.us-east-1.amazonaws.com` -> `us-east-1`.
/// Global endpoints such as `iam.amazonaws.com` return `null`.
String? regionFromAwsHost(String host) {
  final parts = host.split('.');
  if (parts.length == 4 && parts[1].contains('-')) return parts[1];
  return null;
}

String? regionFromAwsUrl(String url) {
  final host = Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return null;
  return regionFromAwsHost(host);
}
