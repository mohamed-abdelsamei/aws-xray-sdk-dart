import 'http_data.dart' show redactUrl, redactUrlsInText;

/// AWS service metadata attached to a subsegment (the `aws` field).
final class AwsData {
  const AwsData({
    required this.operation,
    this.region,
    this.requestId,
    this.tableName,
    this.bucketName,
    this.keyId,
    this.queueUrl,
    this.topicArn,
    this.functionName,
    this.resourceNames,
  });

  final String operation;
  final String? region;
  final String? requestId;

  // Service-specific resource identifiers:
  final String? tableName; // DynamoDB
  final String? bucketName; // S3
  final String? keyId; // KMS
  final String? queueUrl; // SQS
  final String? topicArn; // SNS
  final String? functionName; // Lambda
  final List<String>? resourceNames;

  /// The emitted JSON. [queueUrl] and every [resourceNames] entry share one
  /// redaction ([_redact]); the in-memory values stay raw.
  Map<String, Object?> toJson() => {
        'operation': operation,
        if (region != null) 'region': region,
        if (requestId != null) 'request_id': requestId,
        if (tableName != null) 'table_name': tableName,
        if (bucketName != null) 'bucket_name': bucketName,
        if (keyId != null) 'key_id': keyId,
        if (queueUrl != null) 'queue_url': _redact(queueUrl!, isUrl: true),
        if (topicArn != null) 'topic_arn': topicArn,
        if (functionName != null) 'function_name': functionName,
        if (resourceNames != null)
          'resource_names': [
            for (final r in resourceNames!) _redact(r, isUrl: r == queueUrl),
          ],
      };
}

/// Whole-value URL redaction first, then every URL token left in the text
/// (a value holding several URLs, or text around one). A value that is not
/// known to be a URL ([isUrl]) and has no `scheme:/` or `scheme:\` in it is
/// left as it is, so names and ARNs survive.
String _redact(String value, {required bool isUrl}) =>
    isUrl || _schemeMarker.hasMatch(value)
        ? redactUrlsInText(redactUrl(value))
        : value;

final _schemeMarker = RegExp(r'[:][/\\]');
