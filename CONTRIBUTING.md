# Contributing to Stratus

Thank you for contributing to Stratus. This project is a production-grade native macOS cloud drive manager, so contributions must preserve correctness, resumability, security, and the macOS-first user experience.

## Requirements

- macOS 15.0+
- Xcode 16.3+ with Swift 6
- Swift Package Manager only
- Optional local tools: SwiftFormat, SwiftLint, Sparkle `generate_appcast`
- No Apple Developer ID certificate is required for normal development

## Setup

```bash
git clone https://github.com/williamcachamwri/Stratus.git
cd Stratus
Scripts/ci_bootstrap.sh
swift package resolve
```

## Build, test, lint

```bash
swift build --product Stratus
Scripts/test.sh
Scripts/lint.sh
Scripts/build_unsigned_release.sh
```

`Scripts/build_unsigned_release.sh` creates an unsigned `.app` bundle and release archives under `dist/`. Do not add mandatory signing, notarization, provisioning profile, or certificate requirements to normal builds.

## Branch strategy

Use short-lived branches from `main`:

```bash
git checkout -b feat/provider-health-checks
```

Keep branches focused. A branch can contain many commits, but every commit must touch exactly one completed file.

## Mandatory per-file commit rule

Every created, edited, generated, formatted, or fixed file must be committed separately.

```bash
git status --short
# edit exactly one file
swiftformat <file> || true
swiftlint --strict --path <file> || true
git diff -- <file>
git add -- <file>
git commit -m "type(scope): message" \
  -m "Co-Authored-By: williamcachamwri <2741582+williamcachamwri@users.noreply.github.com>"
git status --short
```

Rules:

- One changed file = one commit.
- Never use `git add .`, `git add -A`, or broad wildcard staging.
- Stage exactly one file with `git add -- <path>`.
- Do not squash commits.
- Do not create mega-commits such as `initial implementation`.
- Use Conventional Commits.
- Every commit must include exactly this trailer:

```text
Co-Authored-By: williamcachamwri <2741582+williamcachamwri@users.noreply.github.com>
```

## Conventional Commits

Use clear scopes:

```text
feat(upload): add multipart resume recovery
fix(sync): preserve conflict queue ordering
test(upload): add chunk slicer boundary tests
ci(github): add unsigned release workflow
docs(develop): document local setup
chore(resources): add provider definitions
```

## Code standards

- Swift 6 strict concurrency is required.
- Prefer actors for shared mutable state.
- New async code should use `async`/`await`, `TaskGroup`, `AsyncStream`, and actors.
- Do not introduce `DispatchQueue` or completion-handler based APIs for new code.
- No force unwraps or `try!` in production code.
- No cleartext secrets, OAuth client secrets, access keys, private Sparkle keys, Apple certificates, or provisioning profiles.
- Errors must explain what failed and how a user can recover.
- UI should use native semantic colors, SF Symbols, system materials, and measured progress data.

## Issue flow

Use the provided GitHub templates:

- Bug reports must include macOS version, Xcode/Swift version, Stratus version or commit, provider type, reproduction steps, expected/actual behavior, logs, and screenshots when relevant.
- Feature requests must include the product area, provider if relevant, user problem, proposed behavior, and acceptance tests.
- Security reports must avoid public secrets and use private security advisories for sensitive vulnerabilities.

## Pull request requirements

A PR should include:

- Summary of user-visible behavior or internal change.
- Validation commands and results.
- Explanation for any validation that could not run locally.
- Confirmation that each file is committed separately.
- Confirmation that unsigned builds still work without Apple signing credentials.

## Sparkle and release policy

Sparkle appcast files live under `Updates/Sparkle/`. Generate appcasts with:

```bash
SPARKLE_GENERATE_APPCAST=/path/to/generate_appcast Scripts/generate_appcast.sh dist/releases
```

Only public Sparkle keys may be committed. Private update signing keys must stay out of the repository.
