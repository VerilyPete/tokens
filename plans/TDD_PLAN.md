# Claude Usage Menu Bar App — TDD Implementation Plan

## Philosophy

This plan restructures the implementation from PLAN.md into **strict Red/Green/Refactor TDD cycles**. Every line of logic is driven by a failing test first.

### Architecture for Testability

The original plan's 6 source files are reorganized into a **library + executable** split:

- **`ClaudeUsageKit`** (library target) — All testable logic: models, protocols, services, formatting
- **`ClaudeUsage`** (executable target) — SwiftUI views and `@main` app entry point
- **`ClaudeUsageTests`** (test target) — Depends on `ClaudeUsageKit`

This split is required because Swift Package Manager cannot `@testable import` an executable target. All business logic lives in the library; the executable is a thin shell.

### Dependency Injection via Protocols

To enable test doubles, the following protocols replace concrete dependencies:

| Protocol | Concrete | Mock |
|---|---|---|
| `KeychainReading` | `KeychainReader` (shells out to `security` CLI) | `MockKeychainReader` (returns canned data) |
| `NetworkSession` | `URLSession` (via extension conformance) | `MockNetworkSession` (returns canned responses) |

`UsageService` accepts these via `init`, defaulting to real implementations in production.

---

## File Structure (TDD)

```
tokens/
├── Package.swift                          # Library + executable + test targets
├── build.sh                               # Build + .app bundle + ad-hoc codesign
├── Resources/
│   └── Info.plist                         # LSUIElement = YES
├── Sources/
│   ├── ClaudeUsageKit/                    # LIBRARY TARGET (testable)
│   │   ├── Models.swift                   # Codable structs, Date.fromAPI, FlexibleCodingKey
│   │   ├── Protocols.swift                # KeychainReading, NetworkSession, KeychainError, UsageError
│   │   ├── KeychainReader.swift           # Concrete keychain via security CLI
│   │   ├── UsageService.swift             # @MainActor @Observable service
│   │   └── Formatting.swift               # UsageLevel enum, time formatting, menu bar label (pure functions)
│   └── ClaudeUsage/                       # EXECUTABLE TARGET (thin UI shell)
│       ├── ClaudeUsageApp.swift            # @main App with MenuBarExtra
│       ├── ContentView.swift              # Popover UI
│       └── UsageBarView.swift             # Reusable progress bar
├── Tests/
│   └── ClaudeUsageTests/                  # TEST TARGET
│       ├── Mocks.swift                    # MockKeychainReader, MockNetworkSession
│       ├── ModelsTests.swift              # JSON parsing, date conversion, flexible keys
│       ├── KeychainParsingTests.swift     # Wrapped/bare format, edge cases
│       ├── FormattingTests.swift          # UsageLevel, time strings, time ago, menuBarLabel
│       └── UsageServiceTests.swift        # Fetch flow, token refresh, error handling
└── plans/
    ├── PLAN.md                            # Architecture reference (unchanged)
    └── TDD_PLAN.md                        # This file
```

---

## TDD Cycles

Each cycle follows **Red → Green → Refactor**:
- **Red:** Write a test that fails (won't compile or assertion fails)
- **Green:** Write the minimum code to make it pass
- **Refactor:** Clean up while keeping tests green

### Phase 1: Project Scaffolding

No tests — just infrastructure:
1. Create `Package.swift` with `ClaudeUsageKit` library, `ClaudeUsage` executable, `ClaudeUsageTests` test target
2. Create `Resources/Info.plist`
3. Create minimal stub files so `swift build` succeeds
4. Verify `swift test` runs (0 tests, 0 failures)

---

### Phase 2: Models — `UsageBucket`

**Cycle 2a: Decode UsageBucket with fractional seconds**
```
RED:   testDecodeBucketWithFractionalSeconds — parse {"utilization":37.0,"resets_at":"2026-02-08T04:59:59.000000+00:00"}
GREEN: Implement UsageBucket with custom init(from:) using Date.fromAPI()
```

**Cycle 2b: Decode UsageBucket without fractional seconds**
```
RED:   testDecodeBucketWithoutFractionalSeconds — parse {"utilization":50.0,"resets_at":"2026-02-08T05:00:00+00:00"}
GREEN: Date.fromAPI() already handles fallback — test should pass (if not, add fallback)
```

**Cycle 2c: UsageBucket rejects malformed dates**
```
RED:   testDecodeBucketWithBadDate — parse {"utilization":37.0,"resets_at":"not-a-date"}, expect DecodingError
GREEN: Throw in init(from:) when Date.fromAPI returns nil
```

**Cycle 2d: Date.fromAPI with Z shorthand timezone**
```
RED:   testParseWithZTimezone — Date.fromAPI("2026-02-08T05:00:00Z") != nil
GREEN: ISO8601FormatStyle already handles Z suffix
```

**Cycle 2e: Date.fromAPI with non-UTC offset**
```
RED:   testParseWithNonUTCOffset — Date.fromAPI("2026-02-08T10:30:00+05:30") equals UTC 05:00
GREEN: ISO8601FormatStyle correctly normalizes timezone offsets
```

---

### Phase 3: Models — `UsageResponse`

**Cycle 3a: Full response with all fields**
```
RED:   testDecodeFullUsageResponse — parse complete JSON from PLAN.md API example
GREEN: Implement UsageResponse with CodingKeys, snake_case decoder
```

**Cycle 3b: Response with null optional fields**
```
RED:   testDecodeResponseWithNullOptionals — seven_day_opus: null, extra_usage omitted
GREEN: Mark fields as Optional, use decodeIfPresent
```

---

### Phase 4: Models — `OAuthCredentials`

**Cycle 4a: CamelCase keys**
```
RED:   testDecodeCredentialsCamelCase — {"accessToken":"tok","refreshToken":"ref","expiresAt":1708123456000}
GREEN: Implement OAuthCredentials with FlexibleCodingKey + decodeFirstMatch
```

**Cycle 4b: Snake_case keys**
```
RED:   testDecodeCredentialsSnakeCase — {"access_token":"tok","refresh_token":"ref","expires_at":1708123456000}
GREEN: decodeFirstMatch tries both variants — should pass
```

**Cycle 4c: Epoch milliseconds to Date**
```
RED:   testCredentialsExpiresAtConversion — verify expiresAt Date equals expected value
GREEN: Convert ms → Date in init(from:) using heuristic: > 1 trillion → ms, else → seconds
```

**Cycle 4d: Epoch seconds heuristic**
```
RED:   testCredentialsExpiresAtSeconds — expiresAt: 1770559200 (seconds) parses correctly
GREEN: Heuristic detects 10-digit timestamps as seconds, skips /1000 division
```

**Cycle 4f: Type mismatch propagated**
```
RED:   testCredentialsTypeMismatchPropagated — accessToken is integer, not string → typeMismatch error
GREEN: decodeFirstMatch's contains(key) + error tracking surfaces the real error, not keyNotFound
```

**Cycle 4e: Optional fields**
```
RED:   testCredentialsOptionalFields — subscriptionType and rateLimitTier absent
GREEN: Use try? for optional fields
```

---

### Phase 5: Models — `TokenRefreshResponse`

**Cycle 5a: Decode refresh response**
```
RED:   testDecodeTokenRefreshResponse — {"access_token":"new","token_type":"Bearer","expires_in":3600,"refresh_token":"newref"}
GREEN: Implement TokenRefreshResponse with explicit CodingKeys for snake_case mapping
```

---

### Phase 5.5: Models — `ExtraUsage`

**Cycle 5.5a: Decode ExtraUsage with non-null credit values**
```
RED:   testDecodeExtraUsageEnabled — is_enabled: true, monthly_limit: 100, used_credits: 12.5, utilization: 12.5
GREEN: ExtraUsage struct with snake_case CodingKeys already handles this
```

**Cycle 5.5b: Decode ExtraUsage with all-null optional fields**
```
RED:   testDecodeExtraUsageDisabled — is_enabled: false, all others null
GREEN: Optional fields decode as nil via decodeIfPresent
```

**Cycle 5.5c: Missing extra_usage key**
```
RED:   testDecodeExtraUsageMissing — minimal JSON without extra_usage key → nil
GREEN: UsageResponse.extraUsage is Optional, decodeIfPresent returns nil
```

---

### Phase 6: Keychain Parsing (unit-testable without Keychain)

**Cycle 6a: Wrapped format**
```
RED:   testParseWrappedCredentials — {"claudeAiOauth":{"accessToken":"tok",...}}
GREEN: KeychainReader.parseCredentials tries Wrapper first
```

**Cycle 6b: Bare format**
```
RED:   testParseBareCredentials — {"accessToken":"tok","refreshToken":"ref",...}
GREEN: Fallback to direct decode
```

**Cycle 6c: Malformed JSON**
```
RED:   testParseMalformedJSON — "not json at all"
GREEN: Throw KeychainError.malformedJSON
```

**Cycle 6d: Trailing whitespace**
```
RED:   testParseWithTrailingNewline — valid JSON + "\n"
GREEN: trimmingCharacters(in: .whitespacesAndNewlines) before parsing
```

**Cycle 6e: Snake_case keys inside wrapper**
```
RED:   testParseSnakeCaseInWrapper — wrapped JSON with snake_case keys inside
GREEN: FlexibleCodingKey handles both key styles regardless of wrapper
```

---

### Phase 7: Formatting — Usage Level Thresholds

**Cycle 7a: Green zone (0–50%)**
```
RED:   testLevelGreen — usageLevel(for: 25) == .green
GREEN: Implement usageLevel(for:) function returning UsageLevel enum
```

**Cycle 7b: Yellow zone (50–80%)**
```
RED:   testLevelYellow — usageLevel(for: 65) == .yellow
GREEN: Add yellow threshold
```

**Cycle 7c: Orange zone (80–90%)**
```
RED:   testLevelOrange — usageLevel(for: 85) == .orange
GREEN: Add orange threshold
```

**Cycle 7d: Red zone (90–100%)**
```
RED:   testLevelRed — usageLevel(for: 95) == .red
GREEN: Add red threshold
```

**Cycle 7e: Boundary values**
```
RED:   testLevelBoundaries — 50→yellow, 80→orange, 90→red, 0→green, 100→red
GREEN: Verify >= comparisons are correct
```

**Cycle 7f: Edge cases**
```
RED:   testLevelEdgeCases — negative→green, >100→red
GREEN: Default case handles negatives; 90... handles >100
```

---

### Phase 8: Formatting — Time Strings

**Cycle 8a: "now" for past/zero**
```
RED:   testTimeStringNow — formatResetTime(seconds: 0) == "now"
GREEN: Implement formatResetTime
```

**Cycle 8b: Minutes only**
```
RED:   testTimeStringMinutes — formatResetTime(seconds: 600) == "10 min"
GREEN: Handle < 90 minutes case
```

**Cycle 8c: Hours and minutes**
```
RED:   testTimeStringHoursMinutes — formatResetTime(seconds: 8040) == "2h 14m"
GREEN: Handle < 24 hours case
```

**Cycle 8d: Days and hours**
```
RED:   testTimeStringDaysHours — formatResetTime(seconds: 108000) == "1d 6h"
GREEN: Handle >= 24 hours case
```

**Cycle 8e: Small positive (< 60s rounds up to 1 min)**
```
RED:   testTimeStringSmallPositive — formatResetTime(seconds: 30) == "1 min"
GREEN: Use max(1, minutes) to ensure at least "1 min"
```

**Cycle 8f: formatResetTime from Date wrapper**
```
RED:   testFormatResetTimeFromDate — formatResetTime(from: future, now: now) == "1h 0m"
GREEN: Implement formatResetTime(from:now:) calling formatResetTime(seconds:)
```

**Cycle 8g: formatTimeAgo — just now**
```
RED:   testFormatTimeAgoJustNow — formatTimeAgo(from: now) == "just now"
GREEN: Implement formatTimeAgo returning "just now" for < 60s
```

**Cycle 8h: formatTimeAgo — minutes and hours**
```
RED:   testFormatTimeAgoMinutes — formatTimeAgo(from: 2minAgo) == "2 min ago"
GREEN: Delegate to formatResetTime for > 60s, append " ago"
```

---

### Phase 9: Formatting — Menu Bar Label

**Cycle 9a: Normal percentage**
```
RED:   testMenuBarLabelNormal — formatMenuBarLabel(utilization: 37, hasError: false, hasData: true) == "37%"
GREEN: Implement formatMenuBarLabel
```

**Cycle 9b: Orange zone suffix**
```
RED:   testMenuBarLabelOrange — formatMenuBarLabel(utilization: 85, ...) == "85%!"
GREEN: Add "!" suffix for >= 80
```

**Cycle 9c: Red zone suffix**
```
RED:   testMenuBarLabelRed — formatMenuBarLabel(utilization: 95, ...) == "95%!!"
GREEN: Add "!!" suffix for >= 90
```

**Cycle 9d: No data yet**
```
RED:   testMenuBarLabelNoData — formatMenuBarLabel(utilization: nil, hasError: false, hasData: false) == "--%"
GREEN: Handle nil utilization
```

**Cycle 9e: Error state**
```
RED:   testMenuBarLabelError — formatMenuBarLabel(utilization: nil, hasError: true, hasData: false) == "!!"
GREEN: Handle error state
```

**Cycle 9f: Error with cached data**
```
RED:   testMenuBarLabelErrorWithCachedData — formatMenuBarLabel(utilization: 37, hasError: true, hasData: true) == "37%"
GREEN: Prioritize cached data over error display
```

---

### Phase 10: UsageService — Form Encoding

**Cycle 10a: Simple values**
```
RED:   testFormEncodeSimple — buildRefreshBody produces "grant_type=refresh_token&..."
GREEN: Implement buildRefreshBody
```

**Cycle 10b: Special characters in token**
```
RED:   testFormEncodeSpecialChars — token with +/= gets percent-encoded
GREEN: Use strict allowed character set (alphanumerics + -._~)
```

**Cycle 10c: Base64-style tokens**
```
RED:   testFormEncodeBase64Token — token "abc123+xyz/end==" encodes correctly
GREEN: Already handled by strict percent-encoding
```

---

### Phase 11: UsageService — Version Parsing

**Cycle 11a: Standard version string**
```
RED:   testParseVersionStandard — "Claude Code v1.2.3" → "1.2.3"
GREEN: Implement parseVersion with regex
```

**Cycle 11b: No version found**
```
RED:   testParseVersionNoMatch — "some other output" → nil
GREEN: Return nil on no match
```

**Cycle 11c: Version with extra text**
```
RED:   testParseVersionExtraText — "Claude Code v0.3.17 (some extra info)" → "0.3.17"
GREEN: Regex captures first version match regardless of trailing text
```

---

### Phase 12: UsageService — Fetch Flow (with Mocks)

**Cycle 12a: Successful fetch**
```
RED:   testFetchSuccess — mock returns valid JSON → usage is populated, error is nil
GREEN: Implement fetchUsage with injected NetworkSession
```

**Cycle 12b: 401 triggers refresh then retry**
```
RED:   testFetch401RefreshAndRetry — first call returns 401, refresh succeeds, retry succeeds
GREEN: Implement refresh-on-401 logic
```

**Cycle 12c: 403 gives specific error**
```
RED:   testFetch403Forbidden — returns .forbidden error, no refresh attempted
GREEN: Handle 403 specifically
```

**Cycle 12d: Network error**
```
RED:   testFetchNetworkError — URLError.notConnectedToInternet → .network error
GREEN: Catch URLError, wrap in .network
```

**Cycle 12e: Keychain error propagates**
```
RED:   testFetchKeychainError — keychain returns .notFound → service.error == .keychain(.notFound)
GREEN: Catch KeychainError in fetchUsage, wrap in .keychain
```

**Cycle 12f: Menu bar label reflects state**
```
RED:   testMenuBarLabelUpdates — before fetch "--%", after fetch "37%"
GREEN: menuBarLabel computed property uses formatMenuBarLabel
```

**Cycle 12g: Subscription type from keychain**
```
RED:   testSubscriptionTypeFromKeychain — credentials with subscriptionType "Max" → service.subscriptionType == "Max"
GREEN: Set subscriptionType from credentials in fetchUsage
```

**Cycle 12h: Decoding error**
```
RED:   testFetchDecodingError — malformed response → .decodingFailed error
GREEN: Catch DecodingError, map to .decodingFailed
```

**Cycle 12i: Headers set correctly**
```
RED:   testFetchSetsHeaders — Authorization, anthropic-beta, User-Agent headers present
GREEN: Set headers on URLRequest in performFetch
```

**Cycle 12j: Token near-expiry triggers proactive refresh**
```
RED:   testProactiveRefresh — token expires in 10 min → refresh before fetch
GREEN: Check tokenExpiresAt before fetch, refresh if < 15 min
```

**Cycle 12k: Refresh failure falls back to keychain re-read**
```
RED:   testRefreshFailureFallsBackToKeychain — refresh fails → re-read keychain → retry
GREEN: On refresh failure, call keychainReader.readCredentials() again
```

**Cycle 12l: 429 triggers transient retry**
```
RED:   testFetch429Retry — first attempt 429, second attempt 200 → usage populated
GREEN: Retry loop in performFetch for 429/5xx status codes
```

**Cycle 12m: 429 exhausts all retries**
```
RED:   testFetch429ExhaustedRetries — all 4 attempts return 429 → .http(429) error, 4 total requests
GREEN: After 3 retries, set error and return
```

**Cycle 12n: 5xx triggers transient retry**
```
RED:   testFetch500Retry — 500 then 200 → usage populated
GREEN: 500...599 range included in retry logic
```

**Cycle 12o: reloadCredentials clears error and re-fetches**
```
RED:   testReloadCredentialsClearsError — keychain error → reload with valid creds → error cleared
GREEN: reloadCredentials sets error = nil, clears tokens, calls fetchUsage
```

**Cycle 12p: Network error triggers transient retry**
```
RED:   testFetchNetworkErrorRetry — URLError(.timedOut) then 200 → usage populated
GREEN: URLError caught in retry loop, retried up to 3 times
```

**Cycle 12q: Decoding error is not retried**
```
RED:   testFetchDecodingErrorNoRetry — malformed JSON → .decodingFailed, only 1 request made
GREEN: DecodingError caught outside retry loop, returns immediately
```

**Cycle 12r: Error with cached data shows cached menu bar label**
```
RED:   testMenuBarLabelWithCachedDataOnError — success then 403 → menuBarLabel still "37%"
GREEN: formatMenuBarLabel prioritizes utilization when hasData is true
```

**Cycle 12s: isLoading transitions**
```
RED:   testIsLoadingTransitions — isLoading false before fetch, false after fetch completes
GREEN: fetchUsage sets isLoading = true on entry, defer { isLoading = false }
```

**Cycle 12t: consecutiveFailures increments and resets**
```
RED:   testConsecutiveFailuresTracking — increments on 403, resets to 0 on success
GREEN: consecutiveFailures += 1 on error paths, = 0 on 200 success
```

---

### Phase 12.5: Error Description Strings

**Cycle 12.5a–j: Verify all errorDescription strings**
```
RED:   testKeychainNotFoundDescription — KeychainError.notFound.errorDescription matches expected string
       testKeychainAccessDeniedDescription — .accessDenied
       testKeychainMalformedDescription — .malformedJSON
       testKeychainProcessErrorDescription — .processError(44)
       testUsageNetworkDescription — UsageError.network(...)
       testUsageHttpDescription — .http(statusCode: 500)
       testUsageUnauthorizedDescription — .unauthorized
       testUsageForbiddenDescription — .forbidden
       testUsageDecodingDescription — .decodingFailed
       testUsageRefreshFailedDescription — .refreshFailed("HTTP 400")
GREEN: All error enums already have errorDescription — tests verify no regressions
```

---

### Phase 13: SwiftUI Views (Limited TDD)

Views are not unit-tested via XCTest — they're verified visually. But the logic they depend on (colors, formatting, labels) is already fully tested in Phases 7–9.

Implement in order:
1. `UsageBarView.swift` — uses `usageLevel(for:)` and `formatResetTime` from `Formatting.swift`
2. `ContentView.swift` — uses `UsageService` (injected)
3. `ClaudeUsageApp.swift` — `@main`, creates service, wires up `MenuBarExtra`

---

### Phase 14: Build Script & Integration

1. Create `build.sh`
2. Manual smoke test: `swift build`, `swift test`, `./build.sh`

---

## Test Inventory Summary

| Test File | # Tests | What's Covered |
|---|---|---|
| `ModelsTests.swift` | 20 | UsageBucket (3), UsageResponse (2), OAuthCredentials (6), TokenRefreshResponse (1), Date.fromAPI (5), ExtraUsage (3) |
| `KeychainParsingTests.swift` | 5 | Wrapped/bare format, malformed JSON, whitespace, snake_case in wrapper |
| `FormattingTests.swift` | 22 | UsageLevel thresholds (6), reset time (5), reset time from Date (2), time ago (3), menu bar label (6) |
| `UsageServiceTests.swift` | 36 | Form encoding (3), version parsing (3), fetch flow (20: 12a–12t), error descriptions (10) |
| **Total** | **83** | All business logic + error messages |

---

## Running Tests

```bash
swift test                           # Run all tests
swift test --filter ModelsTests      # Run one test class
swift test --filter testFetchSuccess # Run one test
```

---

## Key Design Decisions for Testability

1. **Protocol-based DI over mocking frameworks** — No third-party mock libraries. Simple protocol conformances with closures or stored responses.

2. **Pure functions for formatting** — `usageLevel(for:)`, `formatResetTime(seconds:)`, `formatTimeAgo(from:)`, and `formatMenuBarLabel(...)` are free functions, not methods. Easy to test without any object setup.

3. **`parseCredentials(from:)` made `internal`** — The keychain parsing logic is exposed at `internal` visibility so tests can call it directly with test data, without needing a real keychain.

4. **`parseVersion(from:)` and `buildRefreshBody(refreshToken:)` made `internal static`** — Extracted as static methods so they can be tested without constructing a full `UsageService`.

5. **Library/executable split** — `@testable import ClaudeUsageKit` works because it's a library target. The executable target is just 3 view files that import the library.

6. **Intentionally untested I/O boundaries** — The following code paths require real system access and are not unit-tested:
   - `KeychainReader.readCredentials()` and `runSecurityCLI()` — require real macOS Keychain
   - `detectClaudeVersion()` and `runProcess()` — require real filesystem with `claude` binary
   - `startPolling()` / `stopPolling()` lifecycle — involves `NSWorkspace` wake notifications
   - These are kept as thin wrappers over system APIs, with all parseable logic (`parseCredentials`, `parseVersion`) extracted as testable static methods.
