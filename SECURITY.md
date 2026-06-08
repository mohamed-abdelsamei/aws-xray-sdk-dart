# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| Latest (`0.x`) | ✅ |
| Older releases | ❌ — please upgrade |

Only the latest published version on [pub.dev](https://pub.dev/packages/aws_xray_sdk)
receives security fixes. Older versions are not patched.

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Report vulnerabilities privately via GitHub's
[Security Advisories](https://github.com/mohamed-abdelsamei/aws-xray-sdk-dart/security/advisories/new)
(Repository → Security → Advisories → "Report a vulnerability").

Please include:

- A clear description of the vulnerability and its potential impact
- Steps to reproduce or a minimal proof-of-concept
- Affected version(s)
- Any suggested mitigations

### Response timeline

| Step | Target |
|---|---|
| Acknowledgement | ≤ 3 business days |
| Initial assessment | ≤ 7 business days |
| Fix / advisory publication | Depends on severity — critical issues are prioritised |

## Scope

This package is a tracing client. Relevant security areas include:

- **Sensitive data leakage** — trace segments inadvertently capturing secrets,
  credentials, or PII from HTTP headers or request bodies
- **Denial of service** — malformed segment data causing excessive CPU/memory use
- **UDP injection** — crafted trace IDs or segment documents that corrupt daemon state
- **Dependency vulnerabilities** — this package has no runtime dependencies, but
  dev-dependencies (`lints`, `test`, `mocktail`) are kept current via Dependabot

Out of scope: issues in the AWS X-Ray service itself, the X-Ray daemon, or AWS SDKs.
Those should be reported through [AWS Security](https://aws.amazon.com/security/vulnerability-reporting/).
