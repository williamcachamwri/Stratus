# Stratus

A production-grade native macOS cloud drive manager built with Swift 6 + SwiftUI.

[README in Vietnamese](README.vi.md)

---

## Features

- **Multi-provider** — Amazon S3, Google Drive, Dropbox, OneDrive, iCloud Drive, Backblaze B2, Wasabi, Cloudflare R2, Box, SFTP, WebDAV, FTP
- **Parallel chunked upload** — up to 32 concurrent chunks per file, HTTP/2 multiplexed
- **Delta sync** — block-level diff (rsync-inspired); re-upload only changed blocks
- **Crash-proof resume** — SQLite-backed resume tokens survive `kill -9`
- **AIMD congestion control** — TCP-inspired algorithm finds optimal parallelism automatically
- **Client-side encryption** — AES-256-GCM before upload; provider sees only ciphertext
- **Real-time bandwidth graph** — 60-second CoreGraphics sparkline, EWMA-smoothed
- **Bi-directional sync** — FSEvents + provider polling, configurable conflict resolution
- **File Provider extension** — native Finder integration (on-demand download, status badges)
- **SHA-256 end-to-end** — every file verified; checksum mismatch fails loudly

## Requirements

- macOS 15.0+
- Swift 6.0+

## Build

```bash
git clone https://github.com/williamcachamwri/Stratus.git
cd Stratus
swift build --product Stratus
```

Build an unsigned `.app` bundle for local testing:

```bash
Scripts/build_unsigned_release.sh
open dist/Stratus.app
```

## Test

```bash
Scripts/test.sh
```

120+ unit tests and 20+ integration tests with mock providers.

## Architecture

```
Core/
  Upload/        — Chunk engine, bandwidth monitor, AIMD controller
  Download/      — Parallel range downloader, resume store
  Providers/     — S3, Google Drive, Dropbox, OneDrive, iCloud, SFTP, WebDAV…
  Sync/          — Bi-directional sync, conflict resolver, FSEvents journal
  Encryption/    — AES-256-GCM pipeline, Argon2id key derivation
  VirtualFileSystem/ — FileProvider mount, LRU offline cache
  Diagnostics/   — Structured logging, telemetry, network diagnostics
  Networking/    — HTTPClient, TLS pinning, proxy, HTTP/2 session
  Persistence/   — GRDB SQLite, account store, user preferences
  Auth/          — OAuth2 PKCE, biometric guard, Keychain vault

App/
  Features/      — UploadCenter, FileBrowser, SyncManager, MenuBar…
  DesignSystem/  — Colors, Typography, Spacing, Animations
```

## How Stratus Beats CloudMounter

| Feature | CloudMounter | Stratus |
|---|---|---|
| Parallel chunk upload | ✗ | ✓ Up to 32 parallel chunks |
| Delta sync | ✗ | ✓ Block-level diff |
| Progress detail | % only | Speed, ETA, per-chunk, EWMA graph |
| Checksum verification | ✗ | ✓ SHA-256 every file, always |
| Congestion control | ✗ | ✓ AIMD auto-parallelism |
| Client-side encryption | ✗ | ✓ AES-256-GCM, Argon2id key |
| Sync engine | ✗ | ✓ Bi-directional with conflict queue |
| Resume tokens | ✗ | ✓ SQLite, survive crashes |
| File Provider (no FUSE) | ✗ | ✓ Native macOS API |
| Diagnostics export | ✗ | ✓ ZIP: logs, metrics, network trace |

## License

MIT — see [LICENSE](LICENSE).

## Development

See [DEVELOP.md](DEVELOP.md) for local setup, unsigned packaging, Sparkle appcast generation, and troubleshooting.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Every changed file must be committed separately with the required co-author trailer.
