import 'dart:convert';

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

    group('queue url redaction', () {
      const raw = 'https://u:p@sqs.us-east-1.amazonaws.com/123/q?X=1#f';
      const clean = 'https://sqs.us-east-1.amazonaws.com/123/q';

      test('queue_url and matching resource_names entry are redacted', () {
        const d = AwsData(
          operation: 'SendMessage',
          queueUrl: raw,
          resourceNames: ['other', raw],
        );
        final json = d.toJson();
        expect(json['queue_url'], clean);
        expect(json['resource_names'], ['other', clean]);
        expect(d.queueUrl, raw);
        expect(d.resourceNames, ['other', raw]);
      });

      test('resource_names entries are redacted by content, not equality', () {
        const url = 'https://u:SECRETPW@h.example/q?k=v';
        for (final (queue, entry) in <(String?, String)>[
          (url, ' $url '),
          (url, 'HTTPS://u:SECRETPW@h.example/q'),
          (null, url),
          ('', url),
        ]) {
          final d = AwsData(
            operation: 'X',
            queueUrl: queue,
            resourceNames: [entry],
          );
          final out = jsonEncode(d.toJson());
          expect(out, isNot(contains('SECRETPW')), reason: entry);
          expect(d.resourceNames, [entry]);
        }
      });

      test('scheme-less credentialed forms are redacted only as queue_url', () {
        for (final form in [
          '//user:SECRETPW@h.example/q',
          'user:SECRETPW@h.example/1/q'
        ]) {
          final asEntry = AwsData(operation: 'X', resourceNames: [form]);
          expect(asEntry.toJson()['resource_names'], [form], reason: form);

          final asQueue = AwsData(
            operation: 'X',
            queueUrl: form,
            resourceNames: [form],
          );
          final out = jsonEncode(asQueue.toJson());
          expect(out, isNot(contains('SECRETPW')), reason: form);
        }
      });

      test('non-url resource_names entries are unchanged', () {
        const names = [
          'orders',
          'my-bucket',
          'arn:aws:sns:us-east-1:123456789012:topic',
          'arn:aws:kms:us-east-1:123456789012:key/abc-123',
          'arn:aws:lambda:us-east-1:123456789012:function:my-fn',
          'arn:aws:s3:::b/key',
        ];
        const d = AwsData(operation: 'X', resourceNames: names);
        expect(d.toJson()['resource_names'], names);
      });

      test('multi-token, newline and hostile values are clean in both fields',
          () {
        for (final url in [
          'https://h/q https://u:SECRET@x/y',
          'https://h/q\nhttps://u:SECRET@x/y',
          'https://h/q\thttps://u:SECRET@x/y?k=SECRET',
          'https://u:SE/CRET@h/q',
          'https://u:SE?CRET@h/q',
          'https://u:SE#CRET@h/q',
          r'https:\\u:SECRET@h/q',
          '  https://u:SECRET@h/q',
          '\thttps://u:SECRET@h/q',
        ]) {
          final json = AwsData(
            operation: 'X',
            queueUrl: url,
            resourceNames: [url],
          ).toJson();
          expect(json['queue_url'], isNot(contains('SECRET')), reason: url);
          expect(json['queue_url'], isNot(contains('CRET')), reason: url);
          final names = '${json['resource_names']}';
          expect(names, isNot(contains('CRET')), reason: url);
          expect(json['queue_url'], (json['resource_names'] as List).single);
        }
      });

      test('a plain queue url is unchanged', () {
        const d = AwsData(
          operation: 'SendMessage',
          queueUrl: clean,
          resourceNames: [clean],
        );
        expect(d.toJson()['queue_url'], clean);
        expect(d.toJson()['resource_names'], [clean]);
      });

      test('other fields are left alone', () {
        const d = AwsData(
          operation: 'X',
          tableName: 't?x#y',
          resourceNames: ['t?x#y'],
        );
        expect(d.toJson()['table_name'], 't?x#y');
        expect(d.toJson()['resource_names'], ['t?x#y']);
      });

      test('hostile queue urls never leak the secret', () {
        for (final url in [
          'https://u:s3/cret@sqs.x.amazonaws.com/1/q',
          'https://u:s3?cret@sqs.x.amazonaws.com/1/q',
          'https://u:s3#cret@sqs.x.amazonaws.com/1/q',
          'https://u:p@ss@sqs.x.amazonaws.com/1/q',
          r'https:\\u:s3cret@sqs.x.amazonaws.com/1/q',
          '  https://u:s3cret@sqs.x.amazonaws.com/1/q',
          '\thttps://u:s3cret@sqs.x.amazonaws.com/1/q?sig=s3cret',
        ]) {
          final json = AwsData(
            operation: 'X',
            queueUrl: url,
            resourceNames: [url],
          ).toJson();
          final out = '${json['queue_url']} ${json['resource_names']}';
          expect(out, isNot(contains('s3')), reason: url);
          expect(out, isNot(contains('cret')), reason: url);
          expect(out, isNot(contains('sig=')), reason: url);
        }
      });
    });
  });
}
