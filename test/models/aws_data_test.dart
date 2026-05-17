import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('AwsData', () {
    test('toJson includes operation', () {
      const d = AwsData(operation: 'GetItem');
      expect(d.toJson()['operation'], 'GetItem');
    });

    test('toJson omits null service-specific fields', () {
      const d = AwsData(operation: 'GetItem');
      final json = d.toJson();
      expect(json.containsKey('table_name'), isFalse);
      expect(json.containsKey('bucket_name'), isFalse);
      expect(json.containsKey('key_id'), isFalse);
    });

    test('DynamoDB: tableName serialises to table_name', () {
      const d = AwsData(operation: 'PutItem', tableName: 'my-table');
      expect(d.toJson()['table_name'], 'my-table');
    });

    test('S3: bucketName serialises to bucket_name', () {
      const d = AwsData(operation: 'GetObject', bucketName: 'my-bucket');
      expect(d.toJson()['bucket_name'], 'my-bucket');
    });

    test('KMS: keyId serialises to key_id', () {
      const d = AwsData(operation: 'Decrypt', keyId: 'arn:aws:kms:...');
      expect(d.toJson()['key_id'], 'arn:aws:kms:...');
    });

    test('SQS: queueUrl serialises to queue_url', () {
      const d = AwsData(
        operation: 'SendMessage',
        queueUrl: 'https://sqs.us-east-1.amazonaws.com/123/my-queue',
      );
      expect(d.toJson()['queue_url'], contains('my-queue'));
    });

    test('SNS: topicArn serialises to topic_arn', () {
      const d = AwsData(
        operation: 'Publish',
        topicArn: 'arn:aws:sns:us-east-1:123:my-topic',
      );
      expect(d.toJson()['topic_arn'], contains('my-topic'));
    });

    test('region and requestId are included when set', () {
      const d = AwsData(
        operation: 'GetItem',
        region: 'eu-west-1',
        requestId: 'req-abc-123',
      );
      final json = d.toJson();
      expect(json['region'], 'eu-west-1');
      expect(json['request_id'], 'req-abc-123');
    });
  });
}
