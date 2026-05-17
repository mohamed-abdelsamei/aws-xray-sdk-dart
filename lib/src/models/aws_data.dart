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
  final List<String>? resourceNames;

  Map<String, Object?> toJson() => {
        'operation': operation,
        if (region != null) 'region': region,
        if (requestId != null) 'request_id': requestId,
        if (tableName != null) 'table_name': tableName,
        if (bucketName != null) 'bucket_name': bucketName,
        if (keyId != null) 'key_id': keyId,
        if (queueUrl != null) 'queue_url': queueUrl,
        if (topicArn != null) 'topic_arn': topicArn,
        if (resourceNames != null) 'resource_names': resourceNames,
      };
}
