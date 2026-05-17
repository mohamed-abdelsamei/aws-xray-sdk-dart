import '../models/aws_data.dart';

/// Extracts [AwsData] from a serialized Smithy request body or path.
///
/// Each entry corresponds to one AWS service. Extend this map to add support
/// for additional services without changing the interceptor logic.
typedef ResourceExtractor = AwsData Function(
  String operationName,
  Map<String, Object?> requestBody,
);

/// Built-in extractors keyed by client type name.
final Map<String, ResourceExtractor> builtInExtractors = {
  'DynamoDbClient': _ddbExtractor,
  'S3Client': _s3Extractor,
  'KmsClient': _kmsExtractor,
  'SqsClient': _sqsExtractor,
  'SnsClient': _snsExtractor,
};

AwsData _ddbExtractor(String op, Map<String, Object?> body) => AwsData(
      operation: op,
      tableName: body['TableName'] as String?,
    );

AwsData _s3Extractor(String op, Map<String, Object?> body) => AwsData(
      operation: op,
      bucketName: body['Bucket'] as String?,
    );

AwsData _kmsExtractor(String op, Map<String, Object?> body) => AwsData(
      operation: op,
      keyId: body['KeyId'] as String?,
    );

AwsData _sqsExtractor(String op, Map<String, Object?> body) => AwsData(
      operation: op,
      queueUrl: body['QueueUrl'] as String?,
    );

AwsData _snsExtractor(String op, Map<String, Object?> body) => AwsData(
      operation: op,
      topicArn: body['TopicArn'] as String?,
    );

/// Fallback extractor when no service-specific one is registered.
AwsData defaultExtractor(String op, Map<String, Object?> body) =>
    AwsData(operation: op);
