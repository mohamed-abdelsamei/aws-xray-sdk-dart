import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('SqlData', () {
    test('toJson includes required fields', () {
      const d = SqlData(
        url: 'postgres://localhost:5432/mydb',
        databaseType: 'PostgreSQL',
      );
      final json = d.toJson();
      expect(json['url'], 'postgres://localhost:5432/mydb');
      expect(json['database_type'], 'PostgreSQL');
    });

    test('toJson omits null optional fields', () {
      const d = SqlData(url: 'mysql://host/db', databaseType: 'MySQL');
      final json = d.toJson();
      expect(json.containsKey('database_version'), isFalse);
      expect(json.containsKey('driver_version'), isFalse);
      expect(json.containsKey('user'), isFalse);
      expect(json.containsKey('sanitized_query'), isFalse);
    });

    test('toJson includes all optional fields when set', () {
      const d = SqlData(
        url: 'postgres://localhost/db',
        databaseType: 'PostgreSQL',
        databaseVersion: '14.2',
        driverVersion: 'dart_postgres 3.0',
        user: 'admin',
        sanitizedQuery: 'SELECT * FROM users WHERE id = ?',
      );
      final json = d.toJson();
      expect(json['database_version'], '14.2');
      expect(json['driver_version'], 'dart_postgres 3.0');
      expect(json['user'], 'admin');
      expect(json['sanitized_query'], contains('SELECT'));
    });
  });
}
