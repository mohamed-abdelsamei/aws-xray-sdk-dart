## Summary

<!-- What does this PR do and why? One paragraph is enough. -->

## Type of change

<!-- The PR title must follow Conventional Commits — the type here should match. -->

- [ ] `feat` — new feature (minor version bump)
- [ ] `fix` / `perf` — bug fix or performance improvement (patch bump)
- [ ] `feat!` / `fix!` — breaking change (minor bump while < 1.0, major after)
- [ ] `docs` / `test` / `refactor` / `chore` — no version bump

## Checklist

- [ ] `dart analyze --fatal-warnings` passes locally
- [ ] `dart test` passes locally
- [ ] `dart format .` applied (or no Dart files changed)
- [ ] New public API is exported from `lib/aws_xray_sdk.dart` (if applicable)
- [ ] Tests added or updated for the changed behaviour
- [ ] `CHANGELOG.md` updated under the relevant `## x.y.z` section
      _(only required for `feat`, `fix`, `perf`, and breaking changes)_

## CHANGELOG entry

<!-- Paste the line(s) you added to CHANGELOG.md, or write "N/A" for non-versioned changes. -->

```
- <your entry here>
```
