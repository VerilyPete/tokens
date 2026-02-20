# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Usage is a native macOS menu bar app that displays Claude Pro/Max subscription API usage. It polls the Claude Code OAuth API every 2 minutes and shows a percentage in the menu bar with a detailed popover. Built with Swift 6, SwiftUI, zero external dependencies, macOS 14+ (Sonoma).

## Build & Test Commands

```bash
swift build                              # Debug build
swift test                               # All 86 tests
swift test --filter FormattingTests      # Run one test suite
swift test --filter testFetchSuccess     # Run single test
./build.sh                               # Release build + .app bundle (ad-hoc codesigned)
```

## Architecture

**Library/Executable/Test split** — all testable logic lives in `ClaudeUsageKit` (library target); the executable target (`ClaudeUsage`) is a thin SwiftUI shell.

### ClaudeUsageKit (Sources/ClaudeUsageKit/)

- **Models.swift** — Public Codable/Sendable types: `UsageBucket`, `UsageResponse`, `ExtraUsage`, `OAuthCredentials`, `TokenRefreshResponse`. Custom decoders handle camelCase/snake_case keys via `FlexibleCodingKey`, ISO 8601 dates with fractional seconds, and epoch ms/s heuristics.
- **Protocols.swift** — DI interfaces (`KeychainReading`, `NetworkSession`) and typed error enums (`KeychainError`, `UsageError`) with `LocalizedError` conformance. `URLSession` gets retroactive `NetworkSession` conformance.
- **KeychainReader.swift** — Reads Claude Code OAuth credentials by shelling out to `/usr/bin/security` CLI (avoids ACL issues with `SecItemCopyMatching`). Runs in `Task.detached` with 10s timeout. Handles both wrapped (`{claudeAiOauth: {...}}`) and bare JSON formats.
- **UsageService.swift** — `@MainActor @Observable` core service. Manages polling loop (structured concurrency, no Timer), token refresh (form-urlencoded POST with strict percent-encoding), retry with exponential backoff (2/4/8s, up to 3 retries), wake-from-sleep detection, and consecutive failure tracking (extends interval after 3+ failures). API constants (OAuth client ID, beta header) are module-level.
- **Formatting.swift** — Pure functions for color thresholds (`UsageLevel`: green/yellow/orange/red at 50/80/90%), time formatting, menu bar labels ("37%", "85%!", "95%!!", "--%", "!!"), and credits formatting.

### ClaudeUsage (Sources/ClaudeUsage/) — UI shell

- **ClaudeUsageApp.swift** — `@main`, `MenuBarExtra` with `.window` style. Polling starts in `UsageService.init()` (not `.onAppear`, since MenuBarExtra fires it lazily).
- **ContentView.swift** — Popover with usage bars, error-specific help (setup guide for missing credentials, keychain access help), graceful fallback to cached data on transient errors.
- **UsageBarView.swift** — Reusable color-coded progress bar.

### Tests (Tests/ClaudeUsageTests/)

- **Mocks.swift** — `MockKeychainReader` (result queue), `MockNetworkSession` (response queue), `HoldingNetworkSession` (suspends for concurrency tests).
- Tests use Swift Testing framework (`@Suite`, `@Test`), not XCTest.
- DI via protocol initializer: `UsageService(keychainReader:networkSession:startPollingOnInit:)`.

## Key Patterns

- **Swift 6 concurrency throughout** — structured concurrency only (`Task.sleep`/cancellation), `@Observable` (not `@Published`), all public models are `Sendable`.
- **DI via protocols** — `KeychainReading` and `NetworkSession` enable full test isolation with no third-party mocking.
- **Info.plist embedded via linker flags** in Package.swift (`-sectcreate`) so `Bundle.main.infoDictionary` works during development without an .app bundle.
- **Logging** — `os.Logger` with subsystem `com.tokens.claude-usage`. View with: `log stream --predicate 'subsystem == "com.tokens.claude-usage"'`

## CI

GitHub Actions on `macos-15` (Xcode 16.4, Swift 6.1.1): build (debug) → test → release build + bundle → upload artifact.
