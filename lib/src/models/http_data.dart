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
/// `scheme://host[:port]/path` (ADR 0001, F1).
///
/// Works on the raw string, so it never throws and needs no successful parse.
/// Userinfo is stripped first, so a `?`, `#`, or `/` inside a password cannot
/// hide it. Leading whitespace/control characters are trimmed. The authority
/// runs from after `scheme:` plus its whole run of `/` or `\` (or a leading
/// run of two or more; with no scheme, from the start) to the next `/` or `\`,
/// and everything through its last `@` is dropped. If that authority is not a
/// non-empty, valid `host[:port]` (a `/` in the password ended it early),
/// everything through the last `@` in the string is dropped instead. Over-redacting the
/// host is preferred to leaking credentials. Then everything from the first
/// `?` or `#` is cut. Internal: hidden from the package's public exports.
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
  return s.substring(0, authStart) + s.substring(at + 1);
}

String _cutQuery(String s) {
  for (var i = 0; i < s.length; i++) {
    if (s[i] == '?' || s[i] == '#') return s.substring(0, i);
  }
  return s;
}
