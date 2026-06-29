# Sparkle Updates

This directory contains Stratus' direct-release update feed configuration.

Stratus is currently an open-source, unsigned macOS app. Apple Developer ID signing and notarization are not required for local builds or CI artifacts. Sparkle update signing is separate from Apple code signing and should be enabled only after a real Sparkle EdDSA key pair exists.

## Files

- `appcast.xml` — committed template feed. Release automation replaces it with a generated feed when Sparkle's `generate_appcast` tool is available.
- `generate_appcast.sh` — wrapper around Sparkle's official `generate_appcast` binary.
- `sparkle-config.json` — Stratus release/feed metadata used by humans and release automation.

## Generate an appcast

```bash
Scripts/build_unsigned_release.sh 0.1.0
SPARKLE_GENERATE_APPCAST=/path/to/generate_appcast Scripts/generate_appcast.sh dist/releases
```

The generated appcast should be uploaded with the release artifacts:

```text
Stratus-0.1.0.zip
Stratus-0.1.0.dmg
appcast.xml
```

## Signing policy

Do not commit private update signing material. The repository `.gitignore` blocks common key and secret formats, but review every release commit manually.

`Resources/Info.plist` intentionally omits `SUPublicEDKey` until the project owner generates a real Sparkle EdDSA public key. Once added, only the public key belongs in the repository.
