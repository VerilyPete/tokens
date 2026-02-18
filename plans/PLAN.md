# Claude Usage Menu Bar App — Implementation Plan

## Overview

A native macOS menu bar app built with Swift/SwiftUI that displays Claude Pro/Max subscription usage at a glance. Clicking the menu bar icon opens a popover showing 5-hour rolling, 7-day weekly, and per-model (Sonnet/Opus) usage with color-coded progress bars. It auto-refreshes every 2 minutes.

**Design philosophy:** Clean-room implementation with zero external dependencies. We reference [claude-monitor](https://github.com/rjwalters/claude-monitor) for its battle-tested API/keychain knowledge (endpoint URLs, credential JSON structure, edge cases), but write all code from scratch with proper architecture, Swift 6 concurrency, and no SQLite bloat.

---

## Architecture

### Approach: SwiftUI `MenuBarExtra` (macOS 14+)

- **No Xcode required to build** — uses Swift Package Manager + a `build.sh` script
- The build script compiles via `swift build`, packages into a `.app` bundle, and ad-hoc signs it
- `Info.plist` sets `LSUIElement = YES` so the app has no Dock icon — menu bar only
- The menu bar shows the current 5-hour utilization as a text percentage (e.g. `37%`) that updates live
- Clicking it opens a `.window`-style popover with full usage details
- **macOS 14 Sonoma minimum** — required for `@Observable` macro and Swift Charts

### Concurrency Model (Swift 6)

- `UsageService` is `@MainActor @Observable class` — all published state lives on the main thread
- Polling uses structured concurrency: `while !Task.isCancelled { await fetch(); try await Task.sleep(for: .seconds(120)) }`
- No `Timer`, no `ObservableObject`, no `@Published` — pure `@Observable` + `async/await`
- Model structs are `Sendable` automatically (value types only)
- Package.swift specifies `swiftLanguageModes: [.v6]` for compile-time data-race safety

### API Details

| Detail | Value |
|---|---|
| **Usage endpoint** | `GET https://api.anthropic.com/api/oauth/usage` |
| **Profile endpoint** | `GET https://api.anthropic.com/api/oauth/profile` |
| **Token refresh endpoint** | `POST https://console.anthropic.com/v1/oauth/token` |
| **Auth header** | `Authorization: Bearer <accessToken>` |
| **Beta header** | `anthropic-beta: oauth-2025-04-20` |
| **User-Agent** | `claude-code/2.0.32` |
| **OAuth client_id** | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| **Poll interval** | Every 120 seconds |

### API Response Shape (Usage)

```json
{
  "five_hour": {
    "utilization": 37.0,
    "resets_at": "2026-02-08T04:59:59.000000+00:00"
  },
  "seven_day": {
    "utilization": 26.0,
    "resets_at": "2026-02-12T14:59:59.771647+00:00"
  },
  "seven_day_opus": null,
  "seven_day_sonnet": {
    "utilization": 1.0,
    "resets_at": "2026-02-13T20:59:59.771655+00:00"
  },
  "extra_usage": {
    "is_enabled": false,
    "monthly_limit": null,
    "used_credits": null,
    "utilization": null
  }
}
```

Fields like `seven_day_opus` and `seven_day_sonnet` are nullable — they only appear for subscription tiers that have per-model caps.

### Token Refresh Request/Response

**Request** (form-urlencoded, NOT JSON):
```
POST https://console.anthropic.com/v1/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token&refresh_token=<refreshToken>&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e
```

**Response:**
```json
{
  "access_token": "...",
  "token_type": "Bearer",
  "expires_in": 3600,
  "refresh_token": "..."
}
```

`expires_in` is seconds. Convert to epoch milliseconds: `Int64(Date().timeIntervalSince1970 * 1000) + Int64(expiresIn) * 1000`.

**Critical:** Refresh tokens are single-use. If the refresh succeeds server-side but we fail to persist the new tokens, the user is locked out until they re-run `claude login`. We handle this by: (1) never writing back to the keychain (Claude Code owns that), (2) keeping refreshed tokens in memory only for the current session, (3) re-reading from keychain on next app launch.

### Token Retrieval (macOS Keychain)

**Primary method:** Shell out to `security` CLI via `Process`:
```bash
security find-generic-password -s "Claude Code-credentials" -w
```

This is more reliable than `SecItemCopyMatching` for reading another app's credentials — avoids ACL/partition-ID issues and minimizes keychain permission prompts.

**Fallback:** `SecItemCopyMatching` with the Security framework if `Process` fails.

The keychain entry contains JSON with credentials nested under `claudeAiOauth`:
```json
{
  "claudeAiOauth": {
    "accessToken": "...",
    "refreshToken": "...",
    "expiresAt": 1708123456000,
    "subscriptionType": "Pro",
    "rateLimitTier": "tier_1"
  }
}
```

**Edge cases stolen from claude-monitor:**
- Support both camelCase (`accessToken`) and snake_case (`access_token`) key variants
- `expiresAt` is epoch **milliseconds** (not seconds)
- Some Claude Code versions may omit the `claudeAiOauth` wrapper — fall back to top-level keys
- Service name is `"Claude Code-credentials"` (with the hyphen and space)

### Token Lifecycle (Read-Only Strategy)

Unlike claude-monitor, we do **not** write tokens back to the keychain. This avoids:
- Corrupting Claude Code's credential state
- Complex keychain ACL/permission issues
- The catastrophic failure mode where a single-use refresh token is consumed but the write fails

Our lifecycle:
1. **App launch:** Read credentials from keychain via `security` CLI
2. **Each poll:** Use the in-memory access token
3. **On 401 or token near-expiry (15 min):** Refresh the token, store new tokens **in memory only**
4. **On refresh failure:** Re-read from keychain (Claude Code may have refreshed it)
5. **On persistent failure:** Show error in UI with "Run `claude login` in terminal" guidance

---

## File Structure

```
tokens/
├── LICENSE
├── PLAN.md                             ← this file
├── Package.swift                       # SPM manifest, macOS 14+, Swift 6
├── build.sh                            # Build + .app bundle + ad-hoc codesign
├── Resources/
│   └── Info.plist                      # LSUIElement = YES (no dock icon)
└── Sources/
    └── ClaudeUsage/
        ├── ClaudeUsageApp.swift         # @main App with MenuBarExtra
        ├── ContentView.swift            # Popover UI: all usage metrics
        ├── Models.swift                 # Codable structs for API response + credentials
        ├── KeychainReader.swift         # Read-only credential access (security CLI + fallback)
        ├── UsageService.swift           # @MainActor @Observable: API client, polling, token refresh
        └── UsageBarView.swift           # Reusable color-coded progress bar
```

**6 Swift source files, 1 Package.swift, 1 build script, 1 Info.plist** — compact and focused. Zero external dependencies.

---

## Implementation Steps

### Step 1: `Package.swift`

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            path: "Sources/ClaudeUsage",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
```

- **macOS 14+** (for `@Observable`, modern SwiftUI)
- **Swift 6 language mode** for strict concurrency
- **Zero dependencies** — no SQLite, no third-party packages
- `-parse-as-library` needed for SPM executable with `@main`

### Step 2: `Resources/Info.plist`

Minimal plist with:
- `LSUIElement` = `true` (hides from Dock, menu-bar-only app)
- `CFBundleName` = `ClaudeUsage`
- `CFBundleIdentifier` = `com.tokens.claude-usage`
- `CFBundleVersion` = `1.0.0`

### Step 3: `Sources/ClaudeUsage/Models.swift`

Codable, Sendable structs mirroring the API responses:

- `UsageResponse` — top-level with `fiveHour`, `sevenDay`, `sevenDayOpus?`, `sevenDaySonnet?`, `extraUsage?`
- `UsageBucket` — contains `utilization: Double` and `resetsAt: String`
- `ExtraUsage` — contains `isEnabled: Bool`, optional `monthlyLimit`, `usedCredits`, `utilization`
- `TokenRefreshResponse` — `accessToken`, `tokenType`, `expiresIn`, `refreshToken`
- `OAuthCredentials` — parsed from keychain JSON, supports both camelCase and snake_case keys

All use `CodingKeys` with `snake_case` → `camelCase` mapping via `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` where possible.

### Step 4: `Sources/ClaudeUsage/KeychainReader.swift`

A simple `enum KeychainReader` with static async methods (no shared mutable state):

```swift
enum KeychainReader {
    /// Primary: shell out to `security` CLI
    static func readCredentials() async throws -> OAuthCredentials

    /// Fallback: Security framework
    static func readCredentialsViaFramework() throws -> OAuthCredentials
}
```

**Primary method** (`security` CLI via `Process`):
1. Run `security find-generic-password -s "Claude Code-credentials" -w`
2. Parse stdout as JSON
3. Extract `claudeAiOauth` object (or fall back to top-level keys)
4. Parse into `OAuthCredentials`

**Fallback** (`SecItemCopyMatching`):
```swift
let query: [String: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: "Claude Code-credentials",
    kSecReturnData: true,
    kSecMatchLimit: kSecMatchLimitOne
]
```

**Error types:**
```swift
enum KeychainError: Error {
    case notFound           // No Claude Code credentials in keychain
    case accessDenied       // User denied keychain access prompt
    case malformedJSON      // Credential data isn't valid JSON
    case missingToken       // JSON present but no accessToken field
    case processError(Int32) // security CLI exited with non-zero
}
```

### Step 5: `Sources/ClaudeUsage/UsageService.swift`

The core service — `@MainActor @Observable class`:

```swift
@MainActor @Observable
final class UsageService {
    var usage: UsageResponse?
    var error: UsageError?
    var lastUpdated: Date?
    var isLoading = false

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Int64?  // epoch milliseconds
    private var pollTask: Task<Void, Never>?
}
```

**Polling loop** (structured concurrency, not Timer):
```swift
func startPolling() {
    pollTask = Task {
        while !Task.isCancelled {
            await fetchUsage()
            try? await Task.sleep(for: .seconds(120))
        }
    }
}
```

**Fetch flow:**
1. If no token in memory → read from keychain
2. If token expires within 15 minutes → proactively refresh
3. `GET /api/oauth/usage` with auth headers
4. On success → update `usage`, `lastUpdated`, clear `error`
5. On 401 → attempt refresh → retry once
6. On refresh failure → re-read keychain (Claude Code may have refreshed) → retry once
7. On persistent failure → set `error` with user-facing message
8. Transient errors (429, 5xx, network) → exponential backoff (2s, 4s, 8s), max 3 retries

**Required headers for all API requests:**
```swift
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
request.setValue("claude-code/2.0.32", forHTTPHeaderField: "User-Agent")
```

**Token refresh:**
- `POST https://console.anthropic.com/v1/oauth/token`
- Content-Type: `application/x-www-form-urlencoded` (NOT JSON)
- Body: `grant_type=refresh_token&refresh_token=...&client_id=9d1c250a-...`
- On success: store new tokens **in memory only** (never write to keychain)

**Scope validation:**
The usage endpoint requires `user:profile` scope. Users who ran `claude setup-token` instead of `claude login` only have `user:inference` and will get 403. Detect this and show: "Please run `claude login` (not `setup-token`) to grant usage access."

### Step 6: `Sources/ClaudeUsage/UsageBarView.swift`

A reusable SwiftUI view that renders a horizontal progress bar:
- Takes `label: String`, `percentage: Double`, `resetsAt: String?`
- Color-coded: green (0–50%), yellow (50–80%), orange (80–95%), red (95–100%)
- Shows "Resets in X hr Y min" computed from the `resetsAt` ISO 8601 timestamp
- Clean, minimal design with rounded corners and 6pt bar height

**Time formatting** (stolen from claude-monitor):
- ≤ 0s → "now"
- < 90 min → "N min"
- < 24 hrs → "Nh Mm" (e.g. "2h 14m")
- ≥ 24 hrs → "Nd Nh" (e.g. "4d 6h")

### Step 7: `Sources/ClaudeUsage/ContentView.swift`

The main popover view containing:
- A header row with "Claude Usage" and a refresh button (arrow.clockwise SF Symbol)
- `UsageBarView` for **5-Hour Session** usage
- `UsageBarView` for **7-Day Weekly** usage
- Conditional `UsageBarView` for **Sonnet (7-Day)** if present
- Conditional `UsageBarView` for **Opus (7-Day)** if present
- **Extra Usage section** if `extra_usage.is_enabled`:
  - Show `used_credits` as dollar amount (e.g. "$12.50 / $100.00")
  - Warning color if no spending cap is set (`monthly_limit == nil`)
- A "Last updated N min ago" timestamp at the bottom
- An error banner if the API call fails (with descriptive message + retry button)
- **Setup guide** if no credentials found: "Install Claude Code and run `claude login`"
- Fixed width (~300pt) for a clean popover look
- A "Quit" button at the bottom

### Step 8: `Sources/ClaudeUsage/ClaudeUsageApp.swift`

The `@main` app entry point:

```swift
@main
struct ClaudeUsageApp: App {
    @State private var usageService = UsageService()

    var body: some Scene {
        MenuBarExtra {
            ContentView(service: usageService)
        } label: {
            Text(usageService.menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- Menu bar shows live 5-hour percentage as text (e.g. "37%")
- Color-coded text: normal (<90%), orange (90-95%), red (>95%)
- `.window` style gives a proper popover (not just a menu)
- `usageService` is created once and shared

### Step 9: `build.sh`

A shell script that:
1. Runs `swift build -c release`
2. Creates `ClaudeUsage.app/Contents/MacOS/` and `ClaudeUsage.app/Contents/`
3. Copies the built binary into `MacOS/`
4. Copies `Info.plist` into `Contents/`
5. **Ad-hoc codesigns:** `codesign --sign - ClaudeUsage.app`
6. Prints instructions for first-time launch:
   - If Gatekeeper blocks: `xattr -cr ClaudeUsage.app`
   - Auto-start on login: System Settings → General → Login Items

---

## UI Mockup (ASCII)

```
Menu bar:  [... Wi-Fi  Battery  37%  ...]
                                 ↑
                          Claude usage

┌─────────────────────────────────┐
│  Claude Usage         ↻  Quit  │
│─────────────────────────────────│
│                                 │
│  5-Hour Session                 │
│  ██████████████░░░░░░░░  37%    │
│  Resets in 2h 14m               │
│                                 │
│  7-Day Weekly                   │
│  ████████░░░░░░░░░░░░░  26%    │
│  Resets in 4d 6h                │
│                                 │
│  Sonnet (7-Day)                 │
│  █░░░░░░░░░░░░░░░░░░░░   1%   │
│  Resets in 5d 12h               │
│                                 │
│  Updated 2 min ago              │
└─────────────────────────────────┘
```

---

## What We Stole from claude-monitor

These specific implementation details were validated against claude-monitor's working code, saving us significant reverse-engineering effort:

| Detail | What we learned |
|---|---|
| **Keychain service name** | Exactly `"Claude Code-credentials"` (with space and hyphen) |
| **Credential JSON nesting** | Wrapped under `claudeAiOauth` key, with fallback to top-level |
| **Key name variants** | Both `accessToken`/`access_token` camelCase/snake_case must be supported |
| **Token expiry format** | Epoch **milliseconds** (not seconds) |
| **Refresh endpoint URL** | `https://console.anthropic.com/v1/oauth/token` (NOT `api.anthropic.com`) |
| **Refresh content type** | `application/x-www-form-urlencoded` (NOT JSON — our original plan was wrong) |
| **Required headers** | `anthropic-beta: oauth-2025-04-20` + `User-Agent: claude-code/2.0.32` |
| **OAuth client_id** | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| **Proactive refresh window** | 15 minutes before expiry |
| **Retry strategy** | Exponential backoff 2s/4s/8s for transient errors (429, 5xx, network) |
| **Keychain multi-account quirk** | `kSecMatchLimitAll` + `kSecReturnData` doesn't work — must query attributes first, then fetch each individually |
| **Progress bar thresholds** | Red >95%, orange ≥90% (matches their battle-tested UX choices) |

## What We Do Differently

| Decision | claude-monitor | Our approach | Why |
|---|---|---|---|
| **Dependencies** | SQLite.swift | None | We don't need usage history persistence |
| **Keychain access** | `SecItemCopyMatching` primary | `security` CLI primary | More reliable for cross-app reads, fewer permission prompts |
| **Token writeback** | Writes refreshed tokens to SQLite + keychain | In-memory only | Avoids corrupting Claude Code's credential state |
| **Multi-account** | Full multi-account with drag reorder | Single account (v1) | Keep scope minimal; add later if needed |
| **Concurrency** | `Timer` + callbacks | `Task.sleep` + `async/await` | Swift 6 structured concurrency, cleaner cancellation |
| **Architecture** | AppDelegate + NSStatusItem + NSPopover | `MenuBarExtra` + pure SwiftUI | Simpler, less AppKit interop, fewer layout crash workarounds |
| **File count** | 6 source files (~378KB) | 6 source files (target ~150KB) | Same structure, less code |

---

## Requirements

- **macOS 14 Sonoma or later** (for `@Observable`, `MenuBarExtra` `.window` style)
- **Swift 5.9+** with Swift 6 language mode
- **Claude Code** installed and logged in via `claude login` (so OAuth token is in Keychain with `user:profile` scope)
- No Xcode IDE needed — builds from the terminal with `swift build`

## User Workflow

```bash
git clone <this-repo>
cd tokens
chmod +x build.sh
./build.sh                    # Compiles + creates ClaudeUsage.app
open ClaudeUsage.app          # Launches in menu bar
```

If Gatekeeper blocks the app: `xattr -cr ClaudeUsage.app`

To auto-start on login: System Settings → General → Login Items → add `ClaudeUsage.app`.
