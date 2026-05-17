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
    this.userAgent,
    this.clientIp,
    this.xForwardedFor = false,
  });

  final String method;
  final String url;
  final String? userAgent;
  final String? clientIp;
  final bool xForwardedFor;

  Map<String, Object?> toJson() => {
        'method': method,
        'url': url,
        if (userAgent != null) 'user_agent': userAgent,
        if (clientIp != null) 'client_ip': clientIp,
        if (xForwardedFor) 'x_forwarded_for': true,
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
