import 'dart:convert';

import 'package:aws_xray_sdk/src/sender/daemon_address.dart';
import 'package:test/test.dart';

void main() {
  group('parseDaemonAddress', () {
    group('valid input', () {
      const cases = <String?, (String, int)>{
        '127.0.0.1:2000': ('127.0.0.1', 2000),
        'xray:3000': ('xray', 3000),
        '[::1]:2000': ('::1', 2000),
        '::1': ('::1', 2000),
        'tcp:10.0.0.1:2000 udp:10.0.0.2:2001': ('10.0.0.2', 2001),
        'udp:10.0.0.2:2001 tcp:10.0.0.1:2000': ('10.0.0.2', 2001),
        'udp:10.0.0.2:2001': ('10.0.0.2', 2001),
        'udp:[::1]:2001 tcp:[::1]:2000': ('::1', 2001),
        '  127.0.0.1:2000\n': ('127.0.0.1', 2000),
        '[::ffff:127.0.0.1]:2001': ('::ffff:127.0.0.1', 2001),
        'xray:03000': ('xray', 3000),
        null: ('127.0.0.1', 2000),
        '': ('127.0.0.1', 2000),
      };

      for (final MapEntry(key: input, value: expected) in cases.entries) {
        test('${input == null ? 'null' : jsonEncode(input)} -> $expected', () {
          expect(parseDaemonAddress(input), expected);
        });
      }
    });

    group('malformed input falls back to 127.0.0.1:2000', () {
      const cases = <String>[
        'abc:notaport',
        'tcp:1.2.3.4:2000',
        ':2000',
        '127.0.0.1:65536',
        '127.0.0.1:99999',
        '127.0.0.1:0',
        '127.0.0.1:-1',
        '[::1',
        '[::1]x',
        '[]:2000',
        'a:b:c',
        'host1:2000 host2:2001',
        'udp:',
        '   ',
        'udp:10.0.0.2:2001 garbage',
        'garbage udp:10.0.0.2:2001',
        '127.0.0.1:0x7d0',
        '127.0.0.1:+80',
        '127.0.0.1:020000',
      ];

      for (final input in cases) {
        test(jsonEncode(input), () {
          expect(() => parseDaemonAddress(input), returnsNormally);
          expect(parseDaemonAddress(input), ('127.0.0.1', 2000));
        });
      }
    });
  });
}
