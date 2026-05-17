/// SQL database metadata for subsegments that trace database calls.
final class SqlData {
  const SqlData({
    required this.url,
    required this.databaseType,
    this.databaseVersion,
    this.driverVersion,
    this.user,
    this.sanitizedQuery,
  });

  final String url;
  final String databaseType;
  final String? databaseVersion;
  final String? driverVersion;
  final String? user;
  final String? sanitizedQuery;

  Map<String, Object?> toJson() => {
        'url': url,
        'database_type': databaseType,
        if (databaseVersion != null) 'database_version': databaseVersion,
        if (driverVersion != null) 'driver_version': driverVersion,
        if (user != null) 'user': user,
        if (sanitizedQuery != null) 'sanitized_query': sanitizedQuery,
      };
}
