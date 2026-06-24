import 'package:test/test.dart';

// ignore: implementation_imports — region helpers are internal.
import 'package:aws_xray_sdk/src/aws/region.dart';

void main() {
  group('regionFromAwsHost', () {
    test('standard regional endpoint', () {
      expect(
          regionFromAwsHost('dynamodb.us-east-1.amazonaws.com'), 'us-east-1');
      expect(
          regionFromAwsHost('sns.eu-central-1.amazonaws.com'), 'eu-central-1');
    });

    test('China partition (amazonaws.com.cn)', () {
      expect(
        regionFromAwsHost('dynamodb.cn-north-1.amazonaws.com.cn'),
        'cn-north-1',
      );
    });

    test('GovCloud region', () {
      expect(
        regionFromAwsHost('dynamodb.us-gov-west-1.amazonaws.com'),
        'us-gov-west-1',
      );
    });

    test('dualstack endpoint', () {
      expect(
        regionFromAwsHost('s3.dualstack.eu-west-1.amazonaws.com'),
        'eu-west-1',
      );
    });

    test('FIPS endpoints (both placements)', () {
      expect(
        regionFromAwsHost('dynamodb-fips.us-east-1.amazonaws.com'),
        'us-east-1',
      );
      expect(
        regionFromAwsHost('dynamodb.fips-us-east-1.amazonaws.com'),
        'us-east-1',
      );
    });

    test('global endpoints have no region', () {
      expect(regionFromAwsHost('iam.amazonaws.com'), isNull);
      expect(regionFromAwsHost('s3.amazonaws.com'), isNull);
    });

    test('non-AWS or empty host returns null', () {
      expect(regionFromAwsHost('api.example.com'), isNull);
      expect(regionFromAwsHost(''), isNull);
    });
  });

  group('regionFromAwsUrl', () {
    test('extracts region from a full URL', () {
      expect(
        regionFromAwsUrl('https://dynamodb.us-east-1.amazonaws.com/'),
        'us-east-1',
      );
    });

    test('returns null for an unparseable or hostless URL', () {
      expect(regionFromAwsUrl('not a url'), isNull);
    });
  });
}
