import 'dart:async';
import 'dart:io';

import 'package:aws_xray_sdk/aws_xray_sdk.dart';
import 'package:aws_xray_sdk/src/sender/daemon_address.dart';
import 'package:aws_xray_sdk/src/sender/daemon_address_warning.dart';
import 'package:test/test.dart';

void main() {
  late List<XRayDiagnostic> diags;
  late List<String> lines;

  setUp(() {
    diags = [];
    lines = [];
  });

  void warn(String? raw, {bool hook = false}) => warnIfDaemonAddressInvalid(
        raw,
        onDiagnostic: hook ? diags.add : null,
        writeLine: lines.add,
      );

  test('malformed with a hook: one diagnostic, no stderr line', () {
    warn('abc:notaport', hook: true);
    expect(diags, hasLength(1));
    expect(diags.single.code, 'daemon_address_invalid');
    expect(diags.single.message, contains('abc:notaport'));
    expect(diags.single.message, contains('127.0.0.1:2000'));
    expect(lines, isEmpty);
  });

  test('malformed without a hook: exactly one stderr line', () {
    warn('abc:notaport');
    expect(lines, hasLength(1));
    expect(lines.single, contains('abc:notaport'));
    expect(lines.single, contains('127.0.0.1:2000'));
  });

  test('a very long value is shortened in the message', () {
    warn('${'x' * 500}:notaport', hook: true);
    expect(diags.single.message.length, lessThan(300));
  });

  for (final v in [null, '', '   ']) {
    test('unset or blank (${v == null ? 'null' : '"$v"'}) reports nothing', () {
      warn(v, hook: true);
      warn(v);
      expect(diags, isEmpty);
      expect(lines, isEmpty);
    });
  }

  for (final v in [
    'xray:3000',
    '127.0.0.1:2000',
    '[::1]:2000',
    '::1',
    'tcp:10.0.0.1:2000 udp:10.0.0.2:3000',
    'udp:10.0.0.2:3000 tcp:10.0.0.1:2000',
  ]) {
    test('valid "$v" reports nothing', () {
      warn(v, hook: true);
      warn(v);
      expect(diags, isEmpty);
      expect(lines, isEmpty);
    });
  }

  test('isMalformedDaemonAddress agrees with the fallback cases', () {
    for (final v in ['abc:x', 'h:0', 'h:70000', '[::1', 'tcp:h:1', 'a b']) {
      expect(isMalformedDaemonAddress(v), isTrue, reason: v);
    }
    expect(isMalformedDaemonAddress(null), isFalse);
    expect(isMalformedDaemonAddress(''), isFalse);
  });

  test('a throwing hook, an async hook and a throwing writer never throw',
      () async {
    expect(
        () => warnIfDaemonAddressInvalid('bad:x',
            onDiagnostic: (_) => throw StateError('boom')),
        returnsNormally);
    await runZonedGuarded(() async {
      warnIfDaemonAddressInvalid('bad:x',
          onDiagnostic: (_) async => throw StateError('late'));
      await Future<void>.delayed(Duration.zero);
    }, (e, _) => fail('unhandled async error: $e'));
    expect(
        () => warnIfDaemonAddressInvalid('bad:x',
            writeLine: (_) => throw const FormatException('closed')),
        returnsNormally);
  });

  test('the diagnostic goes through the dispatcher: re-entrancy is ignored',
      () {
    warnIfDaemonAddressInvalid('bad:x', onDiagnostic: (d) {
      diags.add(d);
      warnIfDaemonAddressInvalid('bad:y', onDiagnostic: diags.add);
    });
    expect(diags, hasLength(1));
  });

  test('the echoed value is one sanitized, shortened line', () {
    warn('bad\n\x1b[31m:x', hook: true);
    expect(diags.single.message, isNot(contains('\n')));
    expect(diags.single.message, isNot(contains('\x1b')));
    expect(diags.single.message, contains('bad'));
  });

  test('credentials in the echoed value are redacted before the cap', () {
    warn('http://user:s3cr3tpass@host/${'p' * 200}', hook: true);
    expect(diags.single.message, isNot(contains('s3cr3t')));
    expect(diags.single.message, isNot(contains('user:')));
  });

  test('the cap does not split a surrogate pair', () {
    warn('${'a' * 99}\u{1F600}${'b' * 50}:x', hook: true);
    final m = diags.single.message;
    expect(m.codeUnits.where((u) => u >= 0xD800 && u <= 0xDBFF).length,
        m.codeUnits.where((u) => u >= 0xDC00 && u <= 0xDFFF).length);
  });

  group('XRay.configure in a subprocess', () {
    final fixture = File('test/fixtures/configure_fixture.dart').absolute.path;

    Future<ProcessResult> run(String mode, {String? address}) => Process.run(
          Platform.resolvedExecutable,
          [fixture, mode],
          environment: {
            if (address != null) 'AWS_XRAY_DAEMON_ADDRESS': address
          },
          includeParentEnvironment: false,
        );

    int warnings(ProcessResult r) =>
        'daemon address'.allMatches('${r.stderr}').length;

    test('malformed without a hook: one stderr line, run continues', () async {
      final r = await run('plain', address: 'bad:x');
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(warnings(r), 1, reason: '${r.stderr}');
      expect('${r.stderr}'.trim().split('\n'), hasLength(1));
      expect('${r.stdout}', contains('done'));
    });

    test('malformed with a hook: hook called once, no stderr', () async {
      final r = await run('hook', address: 'bad:x');
      expect(r.exitCode, 0);
      expect('daemon_address_invalid'.allMatches('${r.stdout}'), hasLength(1));
      expect('${r.stderr}', isEmpty);
    });

    test('a supplied tracer: no warning at all', () async {
      final r = await run('tracer', address: 'bad:x');
      expect(r.exitCode, 0);
      expect('${r.stderr}', isEmpty);
      expect('${r.stdout}', isNot(contains('daemon_address_invalid')));
    });

    for (final a in [null, '', 'xray:3000', 'udp:h:1 tcp:h:2']) {
      test('"${a ?? 'unset'}" prints nothing', () async {
        for (final mode in ['plain', 'hook']) {
          final r = await run(mode, address: a);
          expect(r.exitCode, 0);
          expect('${r.stderr}', isEmpty);
          expect('${r.stdout}', isNot(contains('daemon_address_invalid')));
        }
      });
    }

    test('a closed stderr does not kill the process', () async {
      final r = await Process.run(
        '/bin/sh',
        ['-c', '"\$0" "\$1" plain 2>&-', Platform.resolvedExecutable, fixture],
        environment: {'AWS_XRAY_DAEMON_ADDRESS': 'bad:x'},
        includeParentEnvironment: false,
      );
      expect(r.exitCode, 0);
      expect('${r.stdout}', contains('done'));
    }, skip: Platform.isWindows ? 'needs /bin/sh' : null);
  });
}
