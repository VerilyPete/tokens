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
│   │   ├── Protocols.swift                # KeychainReading, NetworkSession
│   │   ├── KeychainReader.swift           # Concrete keychain via security CLI
│   │   ├── UsageService.swift             # @MainActor @Observable service
│   │   └── Formatting.swift               # Color thresholds, time formatting (pure functions)
│   └── ClaudeUsage/                       # EXECUTABLE TARGET (thin UI shell)
│       ├── ClaudeUsageApp.swift            # @main App with MenuBarExtra
│       ├── ContentView.swift              # Popover UI
│       └── UsageBarView.swift             # Reusable progress bar
├── Tests/
│   └── ClaudeUsageTests/                  # TEST TARGET
│       ├── Mocks.swift                    # MockKeychainReader, MockNetworkSession
│       ├── ModelsTests.swift              # JSON parsing, date conversion, flexible keys
│       ├── KeychainParsingTests.swift     # Wrapped/bare format, edge cases
│       ├── FormattingTests.swift          # Colors, time strings, menuBarLabel
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
GREEN: Convert ms → Date in init(from:): Date(timeIntervalSince1970: ms / 1000.0)
```

**Cycle 4d: Optional fields**
```
RED:   testCredentialsOptionalFields — subscriptionType and rateLimitTier absent
GREEN: Use try? for optional fields
```

---

### Phase 5: Models — `TokenRefreshResponse`

**Cycle 5a: Decode refresh response**
```
RED:   testDecodeTokenRefreshResponse — {"access_token":"new","token_type":"Bearer","expires_in":3600,"refresh_token":"newref"}
GREEN: Implement TokenRefreshResponse, decode with .convertFromSnakeCase
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

---

### Phase 7: Formatting — Color Thresholds

**Cycle 7a: Green zone (0–50%)**
```
RED:   testColorGreen — usageColor(for: 25) == .green
GREEN: Implement usageColor(for:) function
```

**Cycle 7b: Yellow zone (50–80%)**
```
RED:   testColorYellow — usageColor(for: 65) == .yellow
GREEN: Add yellow threshold
```

**Cycle 7c: Orange zone (80–90%)**
```
RED:   testColorOrange — usageColor(for: 85) == .orange
GREEN: Add orange threshold
```

**Cycle 7d: Red zone (90–100%)**
```
RED:   testColorRed — usageColor(for: 95) == .red
GREEN: Add red threshold
```

**Cycle 7e: Boundary values**
```
RED:   testColorBoundaries — 50→yellow, 80→orange, 90→red, 0→green, 100→red
GREEN: Verify >= comparisons are correct
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

**Cycle 12e: Token near-expiry triggers proactive refresh**
```
RED:   testProactiveRefresh — token expires in 10 min → refresh before fetch
GREEN: Check tokenExpiresAt before fetch, refresh if < 15 min
```

**Cycle 12f: Concurrent refresh guard**
```
RED:   testConcurrentRefreshGuard — two refreshes at once, only one executes
GREEN: isRefreshing flag with early return
```

**Cycle 12g: Refresh failure falls back to keychain re-read**
```
RED:   testRefreshFailureFallsBackToKeychain — refresh fails → re-read keychain → retry
GREEN: On refresh failure, call keychainReader.readCredentials() again
```

---

### Phase 13: SwiftUI Views (Limited TDD)

Views are not unit-tested via XCTest — they're verified visually. But the logic they depend on (colors, formatting, labels) is already fully tested in Phases 7–9.

Implement in order:
1. `UsageBarView.swift` — uses `usageColor(for:)` and `formatResetTime` from `Formatting.swift`
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
| `ModelsTests.swift` | 10 | UsageBucket, UsageResponse, OAuthCredentials, TokenRefreshResponse |
| `KeychainParsingTests.swift` | 4 | Wrapped/bare format, malformed JSON, whitespace |
| `FormattingTests.swift` | 12 | Color thresholds, time strings, menu bar label |
| `UsageServiceTests.swift` | 9 | Form encoding, version parsing, fetch flow, refresh, errors |
| **Total** | **35** | All business logic |

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

2. **Pure functions for formatting** — `usageColor(for:)`, `formatResetTime(seconds:)`, and `formatMenuBarLabel(...)` are free functions, not methods. Easy to test without any object setup.

3. **`parseCredentials(from:)` made `internal`** — The keychain parsing logic is exposed at `internal` visibility so tests can call it directly with test data, without needing a real keychain.

4. **`parseVersion(from:)` and `buildRefreshBody(refreshToken:)` made `internal static`** — Extracted as static methods so they can be tested without constructing a full `UsageService`.

5. **Library/executable split** — `@testable import ClaudeUsageKit` works because it's a library target. The executable target is just 3 view files that import the library.
