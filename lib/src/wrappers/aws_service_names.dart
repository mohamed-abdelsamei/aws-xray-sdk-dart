/// Maps Smithy client type names to X-Ray namespace strings.
///
/// X-Ray uses `"AWS::<ServiceName>"` for the `namespace` field.
const Map<String, String> awsServiceNamespaces = {
  'DynamoDbClient': 'AWS::DynamoDB',
  'S3Client': 'AWS::S3',
  'KmsClient': 'AWS::KMS',
  'SqsClient': 'AWS::SQS',
  'SnsClient': 'AWS::SNS',
  'SecretsManagerClient': 'AWS::SecretsManager',
  'LambdaClient': 'AWS::Lambda',
  'StsClient': 'AWS::STS',
};

/// Returns the X-Ray namespace for a client instance, or `"aws"` if unknown.
String namespaceForClient(Object client) =>
    awsServiceNamespaces[client.runtimeType.toString()] ?? 'aws';
