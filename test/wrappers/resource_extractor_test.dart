import 'package:aws_xray_sdk/src/wrappers/resource_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('builtInExtractors', () {
    test('registers one extractor per supported service', () {
      expect(
        builtInExtractors.keys,
        containsAll([
          'DynamoDbClient',
          'S3Client',
          'KmsClient',
          'SqsClient',
          'SnsClient',
        ]),
      );
    });

    test('DynamoDbClient extracts operation + table_name', () {
      final aws = builtInExtractors['DynamoDbClient']!(
        'GetItem',
        {'TableName': 'orders'},
      );
      final json = aws.toJson();
      expect(json['operation'], 'GetItem');
      expect(json['table_name'], 'orders');
    });

    test('S3Client extracts operation + bucket_name', () {
      final aws = builtInExtractors['S3Client']!(
        'PutObject',
        {'Bucket': 'my-bucket'},
      );
      final json = aws.toJson();
      expect(json['operation'], 'PutObject');
      expect(json['bucket_name'], 'my-bucket');
    });

    test('KmsClient extracts operation + key_id', () {
      final json = builtInExtractors['KmsClient']!(
        'Decrypt',
        {'KeyId': 'key-123'},
      ).toJson();
      expect(json['operation'], 'Decrypt');
      expect(json['key_id'], 'key-123');
    });

    test('SqsClient extracts operation + queue_url', () {
      final json = builtInExtractors['SqsClient']!(
        'SendMessage',
        {'QueueUrl': 'https://sqs/q'},
      ).toJson();
      expect(json['operation'], 'SendMessage');
      expect(json['queue_url'], 'https://sqs/q');
    });

    test('SnsClient extracts operation + topic_arn', () {
      final json = builtInExtractors['SnsClient']!(
        'Publish',
        {'TopicArn': 'arn:aws:sns:topic'},
      ).toJson();
      expect(json['operation'], 'Publish');
      expect(json['topic_arn'], 'arn:aws:sns:topic');
    });

    test('a missing resource field is omitted, operation is kept', () {
      // The body has no TableName — only the operation should be recorded.
      final json = builtInExtractors['DynamoDbClient']!('Scan', {}).toJson();
      expect(json['operation'], 'Scan');
      expect(json.containsKey('table_name'), isFalse);
    });
  });

  group('defaultExtractor', () {
    test('records only the operation name', () {
      final json = defaultExtractor('CustomOp', {'Anything': 1}).toJson();
      expect(json['operation'], 'CustomOp');
      expect(json.containsKey('table_name'), isFalse);
      expect(json.containsKey('bucket_name'), isFalse);
    });
  });
}
