/// Endpoint host suffixes for the known AWS partitions: standard/GovCloud,
/// China, and the US ISO/ISOB air-gapped partitions.
const awsDomainSuffixes = [
  '.amazonaws.com.cn', // China
  '.c2s.ic.gov', // US ISO
  '.sc2s.sgov.gov', // US ISOB
  '.amazonaws.com', // standard + GovCloud
];

/// Returns true for AWS endpoint hosts across known AWS partitions.
bool isAwsHost(String host) {
  final lower = host.toLowerCase();
  for (final suffix in awsDomainSuffixes) {
    if (lower.endsWith(suffix)) return true;
  }
  return false;
}

/// Derives an AWS region from standard regional AWS endpoint hosts, across the
/// standard, China, GovCloud, and ISO partitions, including FIPS and dualstack
/// variants.
///
/// Recognised shapes (label that looks like a region is returned):
///  * `dynamodb.us-east-1.amazonaws.com`           -> `us-east-1`
///  * `dynamodb.cn-north-1.amazonaws.com.cn`       -> `cn-north-1`
///  * `dynamodb.us-gov-west-1.amazonaws.com`       -> `us-gov-west-1`
///  * `s3.dualstack.eu-west-1.amazonaws.com`       -> `eu-west-1`
///  * `dynamodb-fips.us-east-1.amazonaws.com`      -> `us-east-1`
///  * `dynamodb.fips-us-east-1.amazonaws.com`      -> `us-east-1`
///
/// Global endpoints such as `iam.amazonaws.com` and `s3.amazonaws.com` have no
/// region and return `null`.
String? regionFromAwsHost(String host) {
  if (host.isEmpty) return null;
  final lower = host.toLowerCase();

  // Strip the partition suffix so only the service/region labels remain.
  String? body;
  for (final suffix in awsDomainSuffixes) {
    if (lower.endsWith(suffix)) {
      body = lower.substring(0, lower.length - suffix.length);
      break;
    }
  }
  if (body == null) return null;

  // The region is the last region-shaped label among the remaining parts
  // (service first, region last, with optional `dualstack`/`fips` markers).
  final parts = body.split('.');
  for (final part in parts.reversed) {
    final candidate = part.startsWith('fips-') ? part.substring(5) : part;
    if (_looksLikeRegion(candidate)) return candidate;
  }
  return null;
}

/// A region label is `{partition}-{area}-{number}`, e.g. `us-east-1`,
/// `cn-north-1`, `us-gov-west-1`, `eu-central-2`. Requires at least two hyphen
/// groups and a trailing number so service labels like `dynamodb` or
/// `dualstack` are not mistaken for regions.
bool _looksLikeRegion(String s) {
  final groups = s.split('-');
  if (groups.length < 3) return false;
  // Last group is the numeric suffix; preceding groups are lowercase letters.
  if (int.tryParse(groups.last) == null) return false;
  for (final g in groups.take(groups.length - 1)) {
    if (g.isEmpty || !_isAllLetters(g)) return false;
  }
  return true;
}

bool _isAllLetters(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x61 || c > 0x7a) return false; // a-z
  }
  return true;
}

/// [regionFromAwsHost] for a full URL string: parses out the host and derives
/// the region from it. Returns null for unparseable URLs or global endpoints.
String? regionFromAwsUrl(String url) {
  final host = Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return null;
  return regionFromAwsHost(host);
}
