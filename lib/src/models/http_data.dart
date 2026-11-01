/// HTTP request/response data attached to a segment or subsegment.
final class HttpData {
  const HttpData({this.request, this.response});

  final HttpRequestData? request;
  final HttpResponseData? response;

  Map<String, Object?> toJson() => {
        if (request != null) 'request': request!.toJson(),
        if (response != null) 'response': response!.toJson(),
      };
}

final class HttpRequestData {
  const HttpRequestData({
    required this.method,
    required this.url,
    this.traced,
  });

  final String method;

  /// The request URL as given. Only its redacted form (see [redactUrl]) is
  /// emitted by [toJson].
  final String url;
  final bool? traced;

  Map<String, Object?> toJson() => {
        'method': method,
        'url': redactUrl(url),
        if (traced != null) 'traced': traced,
      };
}

final class HttpResponseData {
  const HttpResponseData({required this.status, this.contentLength});

  final int status;
  final int? contentLength;

  Map<String, Object?> toJson() => {
        'status': status,
        if (contentLength != null) 'content_length': contentLength,
      };
}

/// Returns [url] without userinfo, query string, or fragment:
/// `scheme://host[:port]/path`.
///
/// Works on the raw string, so it never throws and needs no successful parse.
/// Userinfo is stripped first, so a `?`, `#`, or `/` inside a password cannot
/// hide it. Leading whitespace/control characters are trimmed. The authority
/// runs from after `scheme:` plus its whole run of `/` or `\` (or a leading
/// run of two or more; with no scheme, from the start) to the next `/` or `\`,
/// and everything through its last `@` is dropped. If that authority is not a
/// non-empty, valid `host[:port]` (a `/` in the password ended it early),
/// everything through the last `@` in the string is dropped instead. If a `?`
/// or `#` comes before the dropped `@`, that `@` may belong to a query: only
/// a valid `host[:port]` before the `?` or `#` is kept, and the rest is
/// dropped. Over-redacting the host is
/// preferred to leaking credentials. Then everything from the first `?` or
/// `#` is cut. Internal: hidden from the package's public exports.
String redactUrl(String url) =>
    _cutQuery(_stripUserinfo(url.replaceFirst(_leadingJunk, '')));

final _leadingJunk = RegExp(r'^[\x00-\x20]+');
// One or more slashes: zero would read `u:p@h` as scheme `u`.
final _schemeSlashes = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:[/\\]+');
final _leadingSlashes = RegExp(r'^[/\\]{2,}');
final _hostPort = RegExp(r'^([^:]*|\[[^\]]*\])(:\d*)?$');

String _stripUserinfo(String s) {
  final int authStart;
  final scheme = _schemeSlashes.firstMatch(s);
  if (scheme != null) {
    authStart = scheme.end;
  } else if (_leadingSlashes.firstMatch(s) case final m?) {
    authStart = m.end;
  } else if (s.startsWith('/') ||
      s.startsWith(r'\') ||
      s.toLowerCase().startsWith('mailto:')) {
    return s; // a path, or a non-hierarchical URI: no authority
  } else {
    authStart = 0; // `u:p@host/p` with no scheme
  }
  var authEnd = s.length;
  for (var i = authStart; i < s.length; i++) {
    if (s[i] == '/' || s[i] == r'\') {
      authEnd = i;
      break;
    }
  }
  var at = s.lastIndexOf('@', authEnd == 0 ? 0 : authEnd - 1);
  final authority = _cutQuery(s.substring(authStart, authEnd));
  if (at < authStart && (authority.isEmpty || !_hostPort.hasMatch(authority))) {
    at = s.lastIndexOf('@');
  }
  if (at < authStart) return s;
  // A `?` or `#` before the `@` means the `@` may be in a query or fragment
  // (`https://h?e=a@b&token=…`): keep nothing after the slashes.
  if (_hasQueryMark(s, authStart, at)) {
    return s.substring(0, authStart) + _hostBeforeQuery(s, authStart, authEnd);
  }
  return s.substring(0, authStart) + s.substring(at + 1);
}

/// The text from [from] to the first `?` or `#` before [authEnd], if it is a
/// non-empty, valid `host[:port]` with no `@`; otherwise `''`.
String _hostBeforeQuery(String s, int from, int authEnd) {
  for (var i = from; i < authEnd; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x3F || c == 0x23) {
      final host = s.substring(from, i);
      return host.isNotEmpty && !host.contains('@') && _hostPort.hasMatch(host)
          ? host
          : '';
    }
  }
  return '';
}

/// Whether `s[from, to)` contains a `?` or `#`.
bool _hasQueryMark(String s, int from, int to) {
  for (var i = from; i < to; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x3F || c == 0x23) return true;
  }
  return false;
}

String _cutQuery(String s) {
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '?' || s[i] == '#') return s.substring(0, i);
  }
  return s;
}

/// Returns [text] with every URL-shaped token redacted by the same rule as
/// [redactUrl]: userinfo, query string, and fragment are dropped, leaving
/// `scheme://host[:port]/path`.
///
/// A token starts at any `:` followed by `/` or `\`, together with the run of
/// scheme characters `[A-Za-z0-9+.-]` right before it (possibly empty or
/// starting with a digit: a malformed scheme never stops redaction). It ends
/// before the next code unit `<= 0x20` or at the end of [text]. Non-ASCII
/// whitespace such as NBSP does not end a token, and a `?` or `#` drops the
/// rest of the token, so trailing quotes or parens after a query are lost too:
/// over-redaction is preferred to leaking. A URL nested in another URL's path
/// is redacted on its own. Text with no `:/` or `:\` is returned unchanged.
///
/// A single hand-written pass, linear in the length of [text]; safe on
/// multi-megabyte `toString()` output. Never throws: on any internal error it
/// fails closed and returns [text] cut before its first `:` that is followed
/// by `/` or `\`. Idempotent. Internal: hidden from the package's public
/// exports.
String redactUrlsInText(String text) {
  try {
    return _redactUrlsInText(text);
  } catch (_) {
    for (var i = 0; i + 1 < text.length; i++) {
      if (text.codeUnitAt(i) == _colon && _isSlash(text.codeUnitAt(i + 1))) {
        return text.substring(0, i);
      }
    }
    return text;
  }
}

const _colon = 0x3A;
const _at = 0x40;
const _question = 0x3F;
const _hash = 0x23;

bool _isSlash(int c) => c == 0x2F || c == 0x5C;

// Mirrors `_stripUserinfo` + `_cutQuery` token by token, without slicing the
// token out: per token, the authority is scanned once, and the end of the
// whitespace-free run (plus its last `@`) is computed once per run, so nested
// tokens never rescan the tail.
String _redactUrlsInText(String s) {
  final n = s.length;
  final out = StringBuffer();
  var copied = 0; // s[copied, i) is kept but not yet written
  var inUrl = false; // inside a token: `?`/`#` drops the rest of the run
  var runEnd = -1; // end of the cached whitespace-free run
  var runLastAt = -1; // last `@` in that run (from where it was scanned)

  void scanRun(int from) {
    if (from < runEnd) return;
    runLastAt = -1;
    var j = from;
    for (; j < n; j++) {
      final c = s.codeUnitAt(j);
      if (c <= 0x20) break;
      if (c == _at) runLastAt = j;
    }
    runEnd = j;
  }

  var i = 0;
  while (i < n) {
    final c = s.codeUnitAt(i);
    if (c <= 0x20) {
      inUrl = false;
      i++;
    } else if (inUrl && (c == _question || c == _hash)) {
      scanRun(i);
      out.write(s.substring(copied, i));
      copied = i = runEnd;
      inUrl = false;
    } else if (c == _colon && i + 1 < n && _isSlash(s.codeUnitAt(i + 1))) {
      // The scheme run before `:` is kept as is, whatever it is (so it needs
      // no scan). Authority: after the whole slash run, up to the next slash
      // or whitespace. After userinfo is dropped, what follows is checked
      // again as an authority (any slashes right after the `@` join the
      // run), exactly as a second pass would read it: this keeps the result
      // idempotent. Each round moves forward, so the scan stays linear.
      var from = i + 1;
      while (true) {
        var a = from;
        while (a < n && _isSlash(s.codeUnitAt(a))) {
          a++;
        }
        var authEnd = a;
        var at = -1;
        for (; authEnd < n; authEnd++) {
          final d = s.codeUnitAt(authEnd);
          if (d <= 0x20 || _isSlash(d)) break;
          if (d == _at) at = authEnd;
        }
        if (at < 0) {
          final authority = _cutQuery(s.substring(a, authEnd));
          if (authority.isEmpty || !_hostPort.hasMatch(authority)) {
            // A `/` in the password ended the authority early: drop through
            // the token's last `@` instead.
            scanRun(i);
            if (runLastAt >= a) at = runLastAt;
          }
        }
        out.write(s.substring(copied, a));
        if (at >= 0 && _hasQueryMark(s, a, at)) {
          // `?` or `#` before the `@`: the `@` may sit in a query
          // (`https://h?e=a@b&token=…`). Keep a valid host[:port] before the
          // mark, drop the rest of the run. The skipped text is consumed, so
          // this stays linear.
          out.write(_hostBeforeQuery(s, a, authEnd));
          scanRun(i);
          copied = i = runEnd;
          break;
        }
        copied = i = at >= 0 ? at + 1 : a;
        if (at < 0 || i >= n) break;
        from = i;
      }
      inUrl = true;
    } else {
      i++;
    }
  }
  out.write(s.substring(copied));
  return out.toString();
}
