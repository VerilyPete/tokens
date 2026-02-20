# Claude Usage

A macOS menu bar app that shows your Claude Pro/Max subscription usage at a glance.

If you use Claude Code heavily, you've probably hit rate limits without warning. Claude Usage sits in your menu bar and polls the Claude API every two minutes, showing your current 5-hour utilization as a simple percentage. Click it to see the full breakdown: 5-hour rolling, 7-day weekly, per-model Sonnet/Opus limits, and extra usage credits if you have them enabled. The bars change color as you approach your limits (green, yellow, orange, red) so you can tell at a glance whether it's a good time to kick off that big refactor.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![Tests](https://img.shields.io/badge/tests-86-green) ![License](https://img.shields.io/badge/license-MIT-lightgrey)

<img src="assets/screenshot.png" alt="Claude Usage popover showing usage bars and extra usage credits" width="300">

## How it works

The app reads your Claude Code OAuth credentials from the macOS keychain (read-only, it never writes to the keychain) and uses them to hit the same usage API that Claude Code itself uses. It handles token refresh automatically, retries with exponential backoff on transient failures, and detects sleep/wake so it doesn't spam errors when your laptop wakes up without a network connection.

The menu bar label gives you a quick read:

| Label | Meaning |
|-------|---------|
| `37%` | Normal usage |
| `85%!` | Getting close (80%+) |
| `95%!!` | Almost at the limit (90%+) |
| `--%` | Waiting for data |
| `!!` | Something's wrong |

## Prerequisites

You need Claude Code installed and logged in. That's it. The app piggybacks on the OAuth credentials that `claude login` stores in your keychain.

You'll also need macOS 14 (Sonoma) or later and Swift 6.0+ (Xcode 16+) to build from source.

## Building

No Xcode project files, no external dependencies. Just clone and build:

```bash
git clone https://github.com/VerilyPete/tokens.git
cd tokens
./build.sh
```

This compiles a release build with Swift Package Manager, packages it into a proper `.app` bundle, and ad-hoc codesigns it. The output is `ClaudeUsage.app` in the project root.

You can also use `swift build` for a quick debug build, or `swift run` to run it directly during development (the Info.plist is embedded via linker flags so everything works without the `.app` wrapper).

## First launch

On first launch, macOS will likely block the app. Depending on your macOS version:

**macOS 14 (Sonoma):** If Gatekeeper blocks it, run `xattr -cr ClaudeUsage.app` and try again.

**macOS 15+ (Sequoia):** Go to System Settings > Privacy & Security and click "Open Anyway."

When the app first accesses the keychain, macOS will show a dialog asking about keychain access. Click **"Always Allow"** (not just "Allow") so it doesn't ask every time.

## Auto-start on login

Add `ClaudeUsage.app` to System Settings > General > Login Items if you want it to launch automatically.

## How it was built

This project was built entirely with Claude Code in a plan-driven workflow. The `plans/` directory tells the story:

**PLAN.md** is the original implementation plan. It started with research into [claude-monitor](https://github.com/rjwalters/claude-monitor) (an existing Python tool for the same purpose) to learn the API endpoints, keychain structure, and edge cases, then designed a clean-room Swift implementation from scratch. The plan went through four rounds of review and revision before any code was written.

**TDD_PLAN.md** restructured the implementation into strict test-driven development cycles. All testable logic lives in a separate library target (`ClaudeUsageKit`) with protocol-based dependency injection, so the full test suite of 86 tests runs without touching the network or keychain.

**CI_PLAN.md** added GitHub Actions CI and folded in four bug fixes that came out of a Qodo code review.

**SIGNING_PLAN.md** designed the Developer ID code signing and notarization pipeline.

The project went from initial commit to signed, notarized, CI-tested app in about four days across 46 commits. Several of those commits were real-world bug fixes discovered by actually using the app against the live API, things like the API returning null where we expected a date, usage buckets being entirely absent for new accounts, and the extra usage field being in cents rather than dollars.

## Architecture

The codebase is split into three targets:

**ClaudeUsageKit** is the library where all the logic lives. Models, keychain reading, API calls, polling, token refresh, formatting. Everything here is testable in isolation through protocol-based dependency injection (`KeychainReading` and `NetworkSession` protocols). It uses Swift 6 structured concurrency throughout with no Timer or Combine dependencies.

**ClaudeUsage** is a thin SwiftUI shell. Three files: the `@main` app entry point with a `MenuBarExtra`, the `ContentView` popover with usage bars and error states, and a reusable `UsageBarView`. About 360 lines total.

**ClaudeUsageTests** has 86 tests using Swift Testing (`@Suite`, `@Test`). The mocks use FIFO queues for deterministic response sequencing, including a `HoldingNetworkSession` that suspends at the network boundary for testing concurrent fetch guards.

## Running the tests

```bash
swift test
```

Or filter to a specific suite:

```bash
swift test --filter FormattingTests
swift test --filter UsageServiceTests
```

## Debugging

The app logs to the unified logging system under `com.tokens.claude-usage`. To watch logs in real time:

```bash
log stream --predicate 'subsystem == "com.tokens.claude-usage"'
```

## License

MIT. See [LICENSE](LICENSE) for details.
