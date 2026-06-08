/// Maps Smithy client **type names** to X-Ray namespace strings.
///
/// X-Ray uses `"AWS::<ServiceName>"` for the `namespace` field. This is the
/// single client-type → namespace resolution path, used by
/// [XRay.registerClient] / [XRay.fromClient] as
/// `awsServiceNamespaces[T.toString()] ?? 'aws'`.
///
/// Note: this is keyed by Smithy client *type name* (e.g. `DynamoDbClient`) and
/// is distinct from the host-prefix → display-name map used by `XRayBaseClient`
/// for `package:http` AWS calls (e.g. `dynamodb` → `DynamoDB`).
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
