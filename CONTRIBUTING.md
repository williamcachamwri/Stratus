# Contributing to Stratus

Thank you for your interest in contributing to Stratus!

## Getting Started

### Requirements
- macOS 15.0+
- Xcode 16.0+ or Swift 6.0+ toolchain
- Swift Package Manager (no Xcode project file)

### Build
```bash
swift build
```

### Test
```bash
swift test
```

### Run
```bash
swift run Stratus
```

## Code Style

- **Swift 6 strict concurrency** — `-strict-concurrency=complete` is enforced
- **Zero force-unwraps** — `!` is a SwiftLint error in production code
- **Zero `try!`** — also a SwiftLint error
- **Typed errors** — all `async throws` functions use typed error enums
- **Actors** — all shared mutable state must be actor-isolated
- Run `swiftformat .` before committing

## Commit Convention

```
feat():     new feature
fix():      bug fix
refactor(): code restructuring without behavior change
test():     test-only changes
chore():    build system, CI, documentation
```

Each file change in its own commit. No `(Phase X)` suffix.

## Pull Request Process

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Make your changes following the code style above
4. Ensure `swift build` and `swift test` both pass
5. Open a pull request with a clear description

## Architecture

See `CLAUDE.md` for a full architecture overview and the module breakdown.

## Reporting Bugs

Open an issue with:
- macOS version
- Stratus version / commit hash
- Steps to reproduce
- Expected vs actual behavior
- Any relevant log output (Stratus → Help → Export Diagnostics)

## Questions

Open a discussion in the GitHub Discussions tab.
