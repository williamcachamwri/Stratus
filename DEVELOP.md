# DEVELOP.md — Stratus Local Development Guide

Stratus is a native macOS cloud drive manager built with Swift 6, SwiftUI, AppKit, Swift Package Manager, actor-based concurrency, and unsigned direct-release packaging.

## Supported toolchain

- macOS 15.0 Sequoia or newer
- Xcode 16.3 or newer with the Swift 6 toolchain selected
- Swift Package Manager only; no CocoaPods, no Carthage, no generated Xcode project is required
- Optional command line tools:
  - SwiftFormat for formatting checks
  - SwiftLint for lint checks
  - Sparkle 2 `generate_appcast` for update feed generation

Check the selected toolchain:

```bash
xcode-select -p
swift --version
xcodebuild -version
```

## Clone and bootstrap

```bash
git clone https://github.com/williamcachamwri/Stratus.git
cd Stratus
Scripts/ci_bootstrap.sh
swift package resolve
```

`Scripts/ci_bootstrap.sh` verifies the local macOS/Xcode/Swift environment. It does not install private certificates and does not require an Apple Developer ID.

## Build unsigned locally

For a fast development build:

```bash
swift build --product Stratus
```

For an unsigned app bundle suitable for manual testing:

```bash
Scripts/build_unsigned_release.sh
open dist/Stratus.app
```

The release script builds the Swift package, creates `dist/Stratus.app`, copies resources, applies ad-hoc code signing when `codesign` is available, and attempts to create both `.zip` and `.dmg` artifacts. It never requires a Developer ID certificate, provisioning profile, notarization credential, or private signing key.

## Test

```bash
Scripts/test.sh
```

The default test entry point runs Swift Package Manager tests with strict concurrency enabled by the package manifest. Integration and performance tests must not use live cloud credentials unless explicitly marked and documented.

## Lint and format

```bash
Scripts/lint.sh
```

The lint script runs SwiftFormat and SwiftLint in check mode when those tools are installed. Missing local lint tools are reported as actionable setup failures on macOS CI.

## Sparkle appcast workflow

Stratus is open-source and currently unsigned. Sparkle update signing is separate from Apple code signing.

1. Build an unsigned artifact:

   ```bash
   Scripts/build_unsigned_release.sh
   ```

2. Generate or refresh the appcast with Sparkle's `generate_appcast` tool:

   ```bash
   SPARKLE_GENERATE_APPCAST=/path/to/generate_appcast Scripts/generate_appcast.sh dist/releases
   ```

3. Publish the generated `appcast.xml` next to the GitHub release artifacts.

Do not commit Sparkle private keys, exported key files, `.p12`, `.pem`, `.key`, `.env`, or secret xcconfig files. Insert `SUPublicEDKey` into `Resources/Info.plist` only after a real public EdDSA key exists.

## Repository rules

Every file change must be committed separately.

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

Never use `git add .`, `git add -A`, broad wildcard staging, squash commits, or mega-commits. Each created, edited, generated, formatted, or fixed file gets exactly one dedicated commit.

## Troubleshooting

### `SwiftUI`, `AppKit`, `Security`, or `FileProvider` is missing

You are not building on macOS with the Apple SDK selected. Use a macOS machine or a GitHub Actions macOS runner.

### The app opens only as a command-line executable

Use `Scripts/build_unsigned_release.sh`; `swift run Stratus` launches the executable directly, while the release script wraps it into a `.app` bundle with `Info.plist` and resources.

### Sparkle appcast generation fails

Set `SPARKLE_GENERATE_APPCAST` to the full path of Sparkle's `generate_appcast` binary. The script also searches common Swift Package Manager artifact locations under `.build/`.

### Code signing fails locally

Unsigned local builds are supported. The script uses ad-hoc signing only when available. A Developer ID certificate is intentionally not required for this repository.
