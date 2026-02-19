# GitHub Actions CI + Bug Fix Plan

## Part 1: Bug Fixes (Issue #2 — Qodo Code Review)

Four bugs to fix TDD-style before wiring up CI. All changes in `UsageService.swift` with new tests in `UsageServiceTests.swift`.

---

### Bug 1: Force-unwrap crash in `buildRefreshBody` (Action Required)

**Problem:** Lines 334–335 force-unwrap `addingPercentEncoding()` with `!`. Although Swift strings can't contain unpaired surrogates, force-unwraps are a crash risk and bad practice in a function that already returns `Data?`.

**Fix:** Replace `!` with `?? key` / `?? value` fallback (percent-encoding failure means the input was already safe, so using the raw value is correct).

**TDD Cycle 10d:**
```
RED:   testFormEncodeNilSafe — buildRefreshBody still returns valid Data (not nil)
       when given a normal token (confirms no regression after removing force-unwraps)
GREEN: Replace `!` with `?? key` and `?? value` in the map closure
```

Minimal change — the existing 3 form-encoding tests (10a–10c) already cover correctness. Cycle 10d just confirms the refactor didn't break anything.

---

### Bug 2: Concurrent `fetchUsage()` calls unguarded (Action Required)

**Problem:** Both the poll loop and wake-notification task can call `fetchUsage()` concurrently. While `@MainActor` serializes synchronous segments, the function yields at every `await`, allowing a second call to interleave. This causes concurrent writes to `usage`, `error`, `lastUpdated`, and `consecutiveFailures`.

**Fix:** Guard on `isLoading` at the top of `fetchUsage()` — if already in-flight, return early.

```swift
public func fetchUsage() async {
    guard !isLoading else { return }  // ← new guard
    isLoading = true
    defer { isLoading = false }
    ...
}
```

**TDD Cycle 12u:**
```
RED:   testFetchWhileAlreadyLoading — set isLoading = true manually, call fetchUsage(),
       verify no network request was made (requestHistory.count == 0)
GREEN: Add `guard !isLoading else { return }` before `isLoading = true`
```

Note: We can't set `isLoading` directly from tests since it's a public var. The test will instead trigger this by calling `fetchUsage()` twice — the mock will have a deliberate delay on the first call so the second call hits the guard. Actually, since `isLoading` is a public `var`, we CAN set it directly in tests:
```swift
service.isLoading = true
await service.fetchUsage()
#expect(mockNetwork.requestHistory.count == 0)
```

---

### Bug 3: Version detection blocks initial data fetch (Recommended)

**Problem:** `startPolling()` calls `await detectClaudeVersion()` before the first `fetchUsage()`. The login-shell fallback (`/bin/sh -l -c "claude --version"`) sources `.zshrc`/`.bash_profile`, which can take 3–15+ seconds on dev machines with heavy environment managers (nvm, rbenv, pyenv, conda). Users see "—%" during this entire delay.

**Fix:** Fire-and-forget version detection — run it concurrently with the first fetch instead of sequentially.

```swift
public func startPolling() {
    stopPolling()

    // Fire-and-forget: version detection runs in parallel with first fetch
    Task { await detectClaudeVersion() }

    pollTask = Task {
        while !Task.isCancelled {
            await fetchUsage()
            let interval = consecutiveFailures >= 3 ? 300.0 : 120.0
            try? await Task.sleep(for: .seconds(interval))
        }
    }
    // ... wake observer unchanged
}
```

The User-Agent will briefly be `claude-code/0.0.0` for the first request if version detection is slow, which is fine — the server doesn't depend on an exact version string.

**No new test needed.** `startPolling()` is an intentionally-untested I/O boundary (per TDD_PLAN.md Phase 14 design decisions). The behavioral change (concurrent vs. sequential) is not observable through the mock-based test harness, and the existing `testFetchSetsHeaders` (Cycle 12i) already verifies the default User-Agent value.

---

### Bug 4: Stale `subscriptionType` after 401 fallback (Action Required)

**Problem:** When a 401 triggers keychain re-read (lines 225–230), `accessToken`, `refreshToken`, and `tokenExpiresAt` are updated but `subscriptionType` is not. If the user changes subscription tier mid-session, the UI badge shows stale info until restart.

**Fix:** Add `subscriptionType = creds.subscriptionType` at line 229.

**TDD Cycle 12v:**
```
RED:   testSubscriptionTypeUpdatedOn401KeychainReread — initial creds have subscriptionType "Pro",
       401 triggers refresh failure, keychain re-read returns creds with subscriptionType "Max",
       verify service.subscriptionType == "Max"
GREEN: Add `subscriptionType = creds.subscriptionType` in the 401 keychain re-read block
```

---

### Test count after bug fixes

| File | Before | After | Delta |
|---|---|---|---|
| `UsageServiceTests.swift` | 36 | 39 | +3 (cycles 10d, 12u, 12v) |
| **Total** | **83** | **86** | **+3** |

---

## Part 2: GitHub Actions CI

### Goal

Add a GitHub Actions workflow that builds, tests, and packages the app on every push and PR.

### Runner

**`macos-15`** — ships with Xcode 16.4 / Swift 6.1.1. Our `Package.swift` requires swift-tools-version:6.0 and `.macOS(.v14)`, so this is the right fit. No Xcode version selection needed — the default works.

### Workflow: `.github/workflows/ci.yml`

#### Triggers

- `push` to `main`
- `pull_request` targeting `main`

#### Single job: `build-and-test`

| Step | Command | Why |
|---|---|---|
| 1. Checkout | `actions/checkout@v4` | Get the code |
| 2. Cache SPM | `actions/cache@v4` on `.build` + SPM caches | Skip dependency resolution on cache hit |
| 3. Build (debug) | `swift build` | Fast compilation check |
| 4. Test | `swift test` | Run all 86 tests, `timeout-minutes: 10` safety net |
| 5. Build (release + bundle) | `./build.sh` | Full integration: release binary, .app bundle, ad-hoc codesign |
| 6. Upload artifact | `actions/upload-artifact@v4` on `ClaudeUsage.app/` | Downloadable .app from any CI run |

#### Cache strategy

- **Path**: `.build`, `~/Library/Caches/org.swift.swiftpm`, `~/Library/org.swift.swiftpm`
- **Key**: `macos-spm-${{ hashFiles('Package.swift') }}`
- **Restore key**: `macos-spm-` (partial hit)

No `Package.resolved` exists (no external dependencies), so we key on `Package.swift`.

#### Artifact

Upload `ClaudeUsage.app/` with 7-day retention. Downloadable from any successful CI run.

### File to create

1. **`.github/workflows/ci.yml`** — single workflow file (~50 lines)

---

## Execution Order

1. Fix Bug 1 (force-unwrap) — test 10d
2. Fix Bug 2 (concurrent fetch guard) — test 12u
3. Fix Bug 3 (version detection non-blocking) — code-only, no new test
4. Fix Bug 4 (stale subscriptionType) — test 12v
5. Update TDD_PLAN.md test inventory (83 → 86)
6. Create `.github/workflows/ci.yml`
7. Commit & push
