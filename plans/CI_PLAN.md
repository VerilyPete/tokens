# GitHub Actions CI Plan

## Goal

Add a GitHub Actions workflow that builds, tests, and packages the Claude Usage menu bar app on every push and PR.

## Runner

**`macos-15`** — ships with Xcode 16.4 / Swift 6.1.1. Our `Package.swift` requires swift-tools-version:6.0 and `.macOS(.v14)`, so this is the right fit. No Xcode version selection needed — the default works.

## Workflow: `.github/workflows/ci.yml`

### Triggers

- `push` to `main`
- `pull_request` targeting `main`

### Single job: `build-and-test`

| Step | Command | Why |
|---|---|---|
| 1. Checkout | `actions/checkout@v4` | Get the code |
| 2. Cache SPM | `actions/cache@v4` on `.build` + `~/Library/Caches/org.swift.swiftpm` | Skip dependency resolution on cache hit |
| 3. Build (debug) | `swift build` | Fast compilation check |
| 4. Test | `swift test` | Run all 83 tests, `timeout-minutes: 10` safety net |
| 5. Build (release + bundle) | `./build.sh` | Full integration: release binary, .app bundle, ad-hoc codesign |
| 6. Upload artifact | `actions/upload-artifact@v4` on `ClaudeUsage.app/` | Downloadable .app from any CI run |

### Cache strategy

- **Path**: `.build`, `~/Library/Caches/org.swift.swiftpm`, `~/Library/org.swift.swiftpm`
- **Key**: `macos-spm-${{ hashFiles('Package.resolved') }}`
- **Restore key**: `macos-spm-` (partial hit when only some deps changed)

Note: We don't have a `Package.resolved` yet (no external dependencies). We'll use `hashFiles('Package.swift')` instead as the cache key, so the cache invalidates when the package definition changes.

### Artifact

Upload `ClaudeUsage.app/` as a build artifact with 7-day retention. This lets anyone download a working .app from any successful CI run.

## Files to create

1. **`.github/workflows/ci.yml`** — the workflow file (single file, ~50 lines)

That's it. No other files needed — `build.sh` already exists and handles the release build + bundle + codesign.
