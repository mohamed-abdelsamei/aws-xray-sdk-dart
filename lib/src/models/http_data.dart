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
  final String url;
  final bool? traced;

  Map<String, Object?> toJson() => {
        'method': method,
        'url': url,
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
