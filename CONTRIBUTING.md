# Contributing to aws_xray_sdk

Thanks for your interest in improving `aws_xray_sdk`. Bug reports, docs fixes,
and code changes are all welcome.

## Before you start

- **Bugs**: open a [bug report](https://github.com/mohamed-abdelsamei/aws-xray-sdk-dart/issues/new?template=bug_report.yml)
  with a minimal reproduction.
- **Features / API changes**: open a [feature request](https://github.com/mohamed-abdelsamei/aws-xray-sdk-dart/issues/new?template=feature_request.yml)
  first so we can agree on the shape before you write code. Anything that
  touches the public API (`lib/aws_xray_sdk.dart`, `XRay`, `XRayTracer`) is
  semver-significant and worth discussing up front.
- **Security issues**: do **not** open a public issue — see [SECURITY.md](SECURITY.md).

Small fixes (typos, docs, obvious bugs) can go straight to a pull request.

## Development setup

Requires Dart SDK `>=3.0.0` (CI runs on `stable` and `beta`).

```bash
git clone https://github.com/mohamed-abdelsamei/aws-xray-sdk-dart.git
cd aws-xray-sdk-dart
dart pub get
```

## Checks

CI runs the following on every pull request. Run them locally before pushing:

```bash
dart format --output=none --set-exit-if-changed .   # formatting
dart analyze --fatal-warnings                       # lints, warnings are errors
dart test                                           # unit tests
dart pub publish --dry-run                          # package validation
```

Useful while iterating:

```bash
dart test test/tracer_test.dart     # a single file
dart test --name "subsegment"       # tests matching a name
```

The test suite does not need AWS credentials or a running daemon — use
`InMemorySender` or `NoopSender` in tests. To see traces end-to-end in the
X-Ray console, see [Local development](README.md#local-development).

## Code guidelines

- Public API lives in `lib/aws_xray_sdk.dart`; implementation lives under
  `lib/src/`. Export new public types from the barrel file, never expose
  `src/` paths directly.
- `Segment` and `Subsegment` are immutable value objects — mutations return a
  new copy.
- Keep the package AOT-safe: no `dart:mirrors`, no `build_runner`.
- Avoid new runtime dependencies. If one is truly needed, explain why in the
  PR.
- Add or update tests for any behaviour change. Serialisation changes should
  be covered by the golden tests in `test/models/`.
- See [doc/architecture.md](doc/architecture.md) for the design and
  [doc/tracing-behavior.md](doc/tracing-behavior.md) for tracing semantics.

## Pull requests

- **Title** must follow [Conventional Commits](https://www.conventionalcommits.org)
  with a lowercase subject — it is enforced by CI and becomes the squash-merge
  commit message:
  - `feat(http): trace redirects as separate subsegments`
  - `fix(sender): handle IPv6 daemon addresses`
  - `docs: clarify Lambda trace header source`
  - Breaking change: `feat!: …` / `fix!: …`
- **CHANGELOG**: for `feat`, `fix`, `perf`, and breaking changes, add an entry
  to `CHANGELOG.md` under the upcoming version's `## x.y.z` section (create it
  if it doesn't exist). Docs/test/chore changes don't need one.
- Keep PRs focused — one logical change per PR is much easier to review.
- Fill in the pull request template checklist.

## Releases

Releases are cut by the maintainer via the manual **Release** workflow in
GitHub Actions, which tags the version and publishes to
[pub.dev](https://pub.dev/packages/aws_xray_sdk) through OIDC. Contributors
don't need to bump versions.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating you agree to uphold it.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
