# Stratus — Codex Instructions

## Project Overview
Stratus is a production-grade native macOS cloud drive manager built with Swift 6 + SwiftUI.
It targets macOS 15.0+ and uses Swift Package Manager exclusively.

## Targets
- **Stratus** (executable): `App/` directory
- **StratusCore** (library): `Core/` directory  
- **StratusCoreTests** (test): `Tests/StratusCoreTests/`

## Commit Rules (MANDATORY)
- Every file write/edit = its own individual git commit
- Co-Authored-By must use: `williamcachamwri <2741582+williamcachamwri@users.noreply.github.com>`
- Conventional commit format: `feat():`, `fix():`, `refactor():`, `test():`, `chore()`
- NO `(Phase X)` suffix in commit title
- Push to GitHub after each commit or batch of commits
- GitHub repo: `https://github.com/williamcachamwri/Stratus.git`

## Code Standards
- Swift 6 strict concurrency: `-strict-concurrency=complete`
- Zero force-unwraps (`!`) in production code
- Zero `try!` in production code
- All `async throws` functions use typed error enums, not bare `Swift.Error`
- Actors for all shared mutable state
- No `@unchecked Sendable` without a comment explaining why

## Architecture
```
Core/
  Upload/        — Upload engine (ChunkEngine, BandwidthMonitor, etc.)
  Download/      — Download engine (DownloadEngine, ParallelRangeDownloader)
  Providers/     — Cloud provider implementations (S3, GDrive, Dropbox…)
  Sync/          — Bi-directional sync engine
  Encryption/    — AES-256-GCM client-side encryption
  VirtualFileSystem/ — FileProvider mount + LRU cache
  Diagnostics/   — Logging, telemetry, network diagnostics
  Networking/    — HTTPClient, TLS pinning, proxy config
  Persistence/   — SQLite via GRDB, account store, preferences
  Auth/          — OAuth2 PKCE, biometric guard, keychain

App/
  Features/      — SwiftUI views (UploadCenter, FileBrowser, SyncManager…)
  DesignSystem/  — Colors, Typography, Spacing, Animations, Icons
```

## Testing
- 120+ unit tests in `Tests/StratusCoreTests/`
- 20+ integration tests in `Tests/StratusCoreTests/UploadPipelineIntegrationTests.swift`
- Run with: `swift test`
- Integration tests use `AppDatabase.makeInMemory()` for isolation

## Dependencies
- `GRDB.swift` 6.x — SQLite for ResumeStore, SyncStateDB, AccountStore
- `Citadel` 0.12.x — SFTP/SSH
- `swift-snapshot-testing` 1.15+ — snapshot tests (test target only)

## Definition of Done
See `/Users/wica/Downloads/STRATUS_CLOUDMOUNTER_KILLER_CODEX_PROMPT.md` lines 2104–2172.
Key automated requirements:
- All 120+ unit tests pass (`swift test`)
- All 20+ integration tests pass
- `swift build` emits zero errors
- Zero force-unwraps in Core/ (SwiftLint: `force_unwrapping: error`)
