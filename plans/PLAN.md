# Claude Usage Menu Bar App — Implementation Plan

## Overview

A native macOS menu bar app built with Swift/SwiftUI that displays Claude Pro/Max subscription usage at a glance. Clicking the menu bar icon opens a popover showing 5-hour rolling, 7-day weekly, and per-model (Sonnet/Opus) usage with color-coded progress bars. It auto-refreshes every 2 minutes.

**Design philosophy:** Clean-room implementation with zero external dependencies. We reference [claude-monitor](https://github.com/rjwalters/claude-monitor) for its battle-tested API/keychain knowledge (endpoint URLs, credential JSON structure, edge cases), but write all code from scratch with proper architecture, Swift 6 concurrency, and no SQLite bloat.

---

## Architecture

### Approach: SwiftUI `MenuBarExtra` (macOS 14+)

- **No Xcode required to build** — uses Swift Package Manager + a `build.sh` script
- The build script compiles via `swift build`, packages into a `.app` bundle, and ad-hoc signs it
- `Info.plist` is embedded into the binary at link time via `-sectcreate` linker flag, so `Bundle.main.infoDictionary` works even outside a `.app` bundle during development
- `Info.plist` sets `LSUIElement = YES` so the app has no Dock icon — menu bar only
- The menu bar shows the current 5-hour utilization as a **monochrome** text percentage (e.g. `37%`) that updates live. Note: `MenuBarExtra` labels are rendered in the system's menu bar style — **colored text is not supported** by the system; it always renders monochrome
- Clicking it opens a `.window`-style popover with full usage details
- **macOS 14 Sonoma minimum** — required for `@Observable` macro

### Known Risk: `MenuBarExtra` Label Updates

There are [well-documented reports](https://developer.apple.com/forums/thread/720625) that `MenuBarExtra` label views do not reliably re-render when state changes. This is a known SwiftUI bug (FB13683957, FB13683950). The `.window` style is somewhat better than `.menu` style but not guaranteed.

With `@Observable`, the label `Text(usageService.menuBarLabel)` should in theory track the property read and trigger re-renders. But `MenuBarExtra` operates at the `Scene` level, not the `View` level, and SwiftUI's observation tracking may not work the same way for scene-level declarations.

**Mitigation strategy (test in order):**
1. Try `@Observable` first — it may just work with macOS 14.x+
2. If not: bridge to `ObservableObject` + `@Published` + `@ObservedObject` (Apple Forums suggest this works)
3. Nuclear option: drop to AppKit's `NSStatusItem` for the menu bar label, keep SwiftUI only for the popover content

**Action:** Prototype the label update first before building the rest of the app. If it doesn't work, pivot to fallback #2 or #3.

### Concurrency Model (Swift 6)

- `UsageService` is `@MainActor @Observable class` — all published state lives on the main thread
- Polling uses structured concurrency: `while !Task.isCancelled { await fetch(); try await Task.sleep(for: .seconds(120)) }`
- No `Timer`, no `ObservableObject`, no `@Published` — pure `@Observable` + `async/await` (unless MenuBarExtra label fallback is needed — see above)
- Model structs are `Sendable` automatically (value types only)
- Package.swift uses `swift-tools-version:6.0` which sets Swift 6 language mode by default for compile-time data-race safety
- **Critical:** `KeychainReader` methods that use `Process` must be explicitly `nonisolated` to avoid blocking the main thread (see Step 4)
- **Critical:** A `isRefreshing` flag must guard against concurrent refresh attempts (manual refresh + poll refresh racing can consume a single-use refresh token and lock the user out)

### App Lifecycle

The plan must handle macOS lifecycle events even without an `NSApplicationDelegate`:

- **Sleep/wake:** Subscribe to `NSWorkspace.didWakeNotification` in `UsageService.init()` to trigger an immediate refresh after wake and avoid error-spamming while the network is unavailable
- **App termination:** If the app is killed mid-refresh, in-memory tokens are lost. This is fine by design — the app re-reads the keychain on next launch
- **Popover dismissal:** `MenuBarExtra` with `.window` style provides no API to programmatically close the popover (FB11984872). Accept that the popover closes only when the user clicks outside it. The "Quit" button calls `NSApplication.shared.terminate(nil)` directly

### API Details

| Detail | Value |
|---|---|
| **Usage endpoint** | `GET https://api.anthropic.com/api/oauth/usage` |
| **Token refresh endpoint** | `POST https://console.anthropic.com/v1/oauth/token` |
| **Auth header** | `Authorization: Bearer <accessToken>` |
| **Beta header** | `anthropic-beta: oauth-2025-04-20` |
| **User-Agent** | Dynamically built: read Claude Code version from `claude --version` at launch, fall back to `claude-code/0.0.0` |
| **OAuth client_id** | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| **Poll interval** | Every 120 seconds |

**Note on base URLs:** The usage endpoint uses `api.anthropic.com` while the token refresh uses `console.anthropic.com`. Do NOT create a single `baseURL` constant — build each request URL explicitly.

**Note on hardcoded values:** The `anthropic-beta` header value is tied to a specific API version. When the beta API graduates, this may need to change. Document it as a constant with a comment explaining its origin.

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

`expires_in` is in **seconds**. Internally, use `Date` objects for all expiry tracking — not epoch milliseconds. Convert at parse time: `Date(timeIntervalSinceNow: TimeInterval(expiresIn))`. The keychain stores `expiresAt` as epoch milliseconds; convert that at read time too: `Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000.0)`. Using a single canonical type (`Date`) prevents milliseconds-vs-seconds confusion.

**Critical:** Refresh tokens are single-use. If the refresh succeeds server-side but we fail to store the new tokens in memory (crash, force-quit), the old refresh token is dead and the new one is lost. Recovery path: the user must re-run `claude login`. This window is microseconds (between HTTP response and assignment) so the risk is negligible, but the recovery path should be documented in the error UI.

### Token Retrieval (macOS Keychain)

**Method:** Shell out to `security` CLI via `Process`:
```bash
security find-generic-password -s "Claude Code-credentials" -w
```

This is more reliable than `SecItemCopyMatching` for reading another app's credentials — avoids ACL/partition-ID issues and minimizes keychain permission prompts.

**No `SecItemCopyMatching` fallback.** The reviewer identified that calling `SecItemCopyMatching` for Claude Code's keychain item will trigger an ACL prompt (our unsigned app isn't in the item's access control list). If the user clicks "Deny", it can poison future `security` CLI calls too. The risk outweighs the benefit. If the `security` CLI fails, show an error — don't try a more dangerous fallback.

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
- `expiresAt` is epoch **milliseconds** (not seconds) — convert to `Date` at parse time
- Some Claude Code versions may omit the `claudeAiOauth` wrapper — fall back to top-level keys
- Service name is `"Claude Code-credentials"` (with the hyphen and space)

**First-launch keychain prompt:** The very first time this app runs and calls `security find-generic-password`, macOS will show a system dialog: *"security wants to use your confidential information stored in 'Claude Code-credentials' in your keychain."* The user **must** click "Always Allow" (not just "Allow") or they'll see this prompt on every poll cycle (every 2 minutes). The app should show a first-launch message in the popover explaining what is about to happen and instructing the user to click "Always Allow."

**Multiple keychain entries:** If the user has multiple Claude Code installations or accounts, `security find-generic-password` returns the first match with no ordering guarantee. For v1, single-account is the supported configuration. Document this limitation.

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
6. **Manual reload:** A "Reload Credentials" button lets the user force a keychain re-read (useful after running `claude login` while the app is running)

---

## File Structure

```
tokens/
├── LICENSE
├── plans/
│   └── PLAN.md                             ← this file
├── Package.swift                       # SPM manifest, macOS 14+, Swift 6
├── build.sh                            # Build + .app bundle + ad-hoc codesign
├── Resources/
│   └── Info.plist                      # LSUIElement = YES (no dock icon)
└── Sources/
    └── ClaudeUsage/
        ├── ClaudeUsageApp.swift         # @main App with MenuBarExtra
        ├── ContentView.swift            # Popover UI: all usage metrics
        ├── Models.swift                 # Codable structs for API response + credentials
        ├── KeychainReader.swift         # Read-only credential access (security CLI only)
        ├── UsageService.swift           # @MainActor @Observable: API client, polling, token refresh
        └── UsageBarView.swift           # Reusable color-coded progress bar
```

**6 Swift source files, 1 Package.swift, 1 build script, 1 Info.plist** — compact and focused. Zero external dependencies.

---

## Implementation Steps

### Step 1: `Package.swift`

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            path: "Sources/ClaudeUsage",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        )
    ]
)
```

- **`swift-tools-version:6.0`** — required for Swift 6 language mode (5.9 does not support `.swiftLanguageMode(.v6)`; tools-version 6.0 sets Swift 6 as the default)
- **macOS 14+** (for `@Observable`, modern SwiftUI)
- **Zero dependencies** — no SQLite, no third-party packages
- **`-parse-as-library` removed** — not needed when no file is named `main.swift` (Swift 5.9+ toolchains accept `@main` without it). Test during build and add back only if needed
- **`Info.plist` embedded via linker** — `-sectcreate __TEXT __info_plist` embeds the plist into the binary so `Bundle.main.infoDictionary` works even outside a `.app` bundle (during `swift run` development). Without this, `swift run` would show a Dock icon and have no bundle identity
- **Note on `unsafeFlags`:** Packages using `unsafeFlags` cannot be consumed as dependencies by other packages. Fine for a standalone app

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
- `OAuthCredentials` — parsed from keychain JSON, supports both camelCase and snake_case keys. Stores `expiresAt` as `Date` (converted from epoch milliseconds at parse time)

All use `CodingKeys` with `snake_case` → `camelCase` mapping via `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` where possible.

### Step 4: `Sources/ClaudeUsage/KeychainReader.swift`

A simple `enum KeychainReader` with `nonisolated` static async methods (no shared mutable state):

```swift
enum KeychainReader {
    /// Shell out to `security` CLI — runs off main thread
    nonisolated static func readCredentials() async throws -> OAuthCredentials {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                // Read stdout, parse JSON, call continuation.resume
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

**Why `nonisolated`:** `Process` is not `Sendable` (it's a mutable class). In Swift 6 strict mode, `@MainActor` methods cannot create and run a `Process` off the main actor. By marking the method `nonisolated`, the `Process` is created and consumed entirely within a non-isolated context, avoiding both Sendability issues and main thread blocking.

**Why `terminationHandler` + continuation instead of `waitUntilExit()`:** `waitUntilExit()` is synchronous and blocking. On a locked keychain or when a permission dialog is shown, it can block indefinitely. The continuation pattern makes it truly async.

**Error types:**
```swift
enum KeychainError: Error, LocalizedError {
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
    // Published state (drives UI)
    var usage: UsageResponse?
    var error: UsageError?
    var lastUpdated: Date?
    var isLoading = false

    // Token state (in-memory only, never written to keychain)
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiresAt: Date?  // canonical Date, not epoch millis
    private var pollTask: Task<Void, Never>?

    // Refresh guard — prevents concurrent refresh attempts from racing
    private var isRefreshing = false

    // User-Agent built from `claude --version` at init
    private var userAgent: String = "claude-code/0.0.0"
}
```

**Polling loop** (structured concurrency, not Timer):
```swift
func startPolling() {
    pollTask = Task {
        await detectClaudeVersion()  // set userAgent
        while !Task.isCancelled {
            await fetchUsage()
            try? await Task.sleep(for: .seconds(120))
        }
    }
}

func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
}
```

**Note:** Cancel the poll task via `stopPolling()` rather than relying on `deinit` — there's a [known Swift bug](https://github.com/swiftlang/swift/issues/79551) where accessing `@Observable` properties in `deinit` produces concurrency errors.

**Sleep/wake handling** (subscribe in `init()`):
```swift
init() {
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification,
        object: nil, queue: .main
    ) { [weak self] _ in
        Task { @MainActor in
            // Brief delay for network to come back up
            try? await Task.sleep(for: .seconds(3))
            await self?.fetchUsage()
        }
    }
}
```

**Fetch flow:**
1. If no token in memory → read from keychain (via `nonisolated` `KeychainReader`)
2. If token expires within 15 minutes → proactively refresh
3. `GET /api/oauth/usage` with auth headers
4. On success → update `usage`, `lastUpdated`, clear `error`
5. On 401 → attempt refresh → retry once
6. On refresh failure → re-read keychain (Claude Code may have refreshed) → retry once
7. On persistent failure → set `error` with user-facing message
8. Transient errors (429, 5xx, network) → exponential backoff (2s, 4s, 8s), max 3 retries

**Concurrent refresh guard:**
```swift
private func refreshTokenIfNeeded() async -> Bool {
    guard !isRefreshing else { return false }  // already refreshing
    isRefreshing = true
    defer { isRefreshing = false }
    // ... perform refresh ...
}
```

**Required headers for all API requests:**
```swift
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
request.setValue(userAgent, forHTTPHeaderField: "User-Agent")  // dynamic
```

**Token refresh:**
- `POST https://console.anthropic.com/v1/oauth/token`
- Content-Type: `application/x-www-form-urlencoded` (NOT JSON)
- Body: `grant_type=refresh_token&refresh_token=...&client_id=9d1c250a-...`
- On success: store new tokens **in memory only** (never write to keychain), convert `expires_in` seconds to `Date` immediately

**Scope validation:**
The usage endpoint requires `user:profile` scope. Users who ran `claude setup-token` instead of `claude login` only have `user:inference` and will get 403. Detect this and show: "Please run `claude login` (not `setup-token`) to grant usage access."

**Logging:**
Use `os.Logger` with the subsystem `com.tokens.claude-usage` for lightweight structured logging:
```swift
import os
private let logger = Logger(subsystem: "com.tokens.claude-usage", category: "UsageService")
```

Log at strategic points:
- Keychain read success/failure
- API request status codes
- Token refresh attempts and outcomes
- Sleep/wake events

This uses the unified logging system — viewable via `Console.app` or `log stream --predicate 'subsystem == "com.tokens.claude-usage"'` — with zero file I/O overhead.

### Step 6: `Sources/ClaudeUsage/UsageBarView.swift`

A reusable SwiftUI view that renders a horizontal progress bar:
- Takes `label: String`, `percentage: Double`, `resetsAt: String?`
- Color-coded: green (0–50%), yellow (50–80%), orange (80–95%), red (95–100%)
- Shows "Resets in X hr Y min" computed from the `resetsAt` ISO 8601 timestamp
- Clean, minimal design with rounded corners and 6pt bar height

**Accessibility:**
```swift
.accessibilityLabel("\(label) usage")
.accessibilityValue("\(Int(percentage)) percent, resets in \(resetTimeDescription)")
```

Every `UsageBarView` must have `.accessibilityLabel` and `.accessibilityValue` so VoiceOver users can read usage information from the colored bars.

**Time formatting** (stolen from claude-monitor):
- ≤ 0s → "now"
- < 90 min → "N min"
- < 24 hrs → "Nh Mm" (e.g. "2h 14m")
- ≥ 24 hrs → "Nd Nh" (e.g. "4d 6h")

### Step 7: `Sources/ClaudeUsage/ContentView.swift`

The main popover view containing:
- A header row with "Claude Usage" and a refresh button (arrow.clockwise SF Symbol)
- **First-launch message** (shown before first keychain read): explains the upcoming keychain permission dialog and instructs user to click "Always Allow"
- `UsageBarView` for **5-Hour Session** usage
- `UsageBarView` for **7-Day Weekly** usage
- Conditional `UsageBarView` for **Sonnet (7-Day)** if present
- Conditional `UsageBarView` for **Opus (7-Day)** if present
- **Extra Usage section** if `extra_usage.is_enabled`:
  - Show `used_credits` as dollar amount (e.g. "$12.50 / $100.00")
  - Warning color if no spending cap is set (`monthly_limit == nil`)
- A "Last updated N min ago" timestamp at the bottom
- A **"Reload Credentials"** button — forces a keychain re-read (useful after running `claude login` while the app is running)
- An error banner if the API call fails (with descriptive message + retry button)
- **Setup guide** if no credentials found: "Install Claude Code and run `claude login`"
- Fixed width (~300pt) for a clean popover look
- A "Quit" button at the bottom (calls `NSApplication.shared.terminate(nil)`)

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
            Text(usageService.menuBarLabel)  // e.g. "37%"
        }
        .menuBarExtraStyle(.window)
    }
}
```

- Menu bar shows live 5-hour percentage as monochrome text (e.g. "37%")
- **No colored text** — the system renders `MenuBarExtra` labels in system menu bar style (monochrome). Use a threshold-based suffix instead: "37%" / "92%!" / "98%!!" to convey urgency
- `.window` style gives a proper popover (not just a menu)
- `usageService` is created once and shared

**If `@Observable` label updates don't work** (see Known Risk above), replace `@State` with `@StateObject` and bridge to `ObservableObject`:
```swift
// Fallback if @Observable doesn't drive MenuBarExtra label updates
@StateObject private var usageService = UsageServiceObservable()
```

### Step 9: `build.sh`

A shell script that:
1. Runs `swift build -c release`
2. Creates `ClaudeUsage.app/Contents/MacOS/` and `ClaudeUsage.app/Contents/`
3. Copies the built binary into `MacOS/`
4. Copies `Info.plist` into `Contents/` (for `.app` bundle — the binary also has it embedded via linker, but the bundle copy is the canonical location for a proper `.app`)
5. **Ad-hoc codesigns:** `codesign --sign - ClaudeUsage.app`
6. Prints instructions for first-time launch:
   - **macOS 14 (Sonoma):** If Gatekeeper blocks: `xattr -cr ClaudeUsage.app`
   - **macOS 15 (Sequoia) and later:** `xattr -cr` is no longer sufficient. Users must go to **System Settings → Privacy & Security** and explicitly click "Open Anyway" for the app
   - **Keychain access:** On first launch, click "Always Allow" when macOS asks about keychain access
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
│  Reload Credentials             │
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
| **Required headers** | `anthropic-beta: oauth-2025-04-20` + User-Agent matching Claude Code |
| **OAuth client_id** | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| **Proactive refresh window** | 15 minutes before expiry |
| **Retry strategy** | Exponential backoff 2s/4s/8s for transient errors (429, 5xx, network) |
| **Keychain multi-account quirk** | `kSecMatchLimitAll` + `kSecReturnData` doesn't work — must query attributes first, then fetch each individually |
| **Progress bar thresholds** | Red >95%, orange ≥90% (matches their battle-tested UX choices) |

## What We Do Differently

| Decision | claude-monitor | Our approach | Why |
|---|---|---|---|
| **Dependencies** | SQLite.swift | None | We don't need usage history persistence |
| **Keychain access** | `SecItemCopyMatching` primary | `security` CLI only | More reliable for cross-app reads, fewer permission prompts, no dangerous fallback |
| **Token writeback** | Writes refreshed tokens to SQLite + keychain | In-memory only | Avoids corrupting Claude Code's credential state |
| **Multi-account** | Full multi-account with drag reorder | Single account (v1) | Keep scope minimal; add later if needed |
| **Concurrency** | `Timer` + callbacks | `Task.sleep` + `async/await` | Swift 6 structured concurrency, cleaner cancellation |
| **Architecture** | AppDelegate + NSStatusItem + NSPopover | `MenuBarExtra` + pure SwiftUI | Simpler, less AppKit interop, fewer layout crash workarounds |
| **File count** | 6 source files (~378KB) | 6 source files (target ~150KB) | Same structure, less code |

---

## Known Risks & Limitations (v1)

1. **`MenuBarExtra` label may not update** — See "Known Risk" section above. Must prototype first
2. **Single-account only** — Multiple Claude Code keychain entries may return the wrong account's credentials
3. **Keychain permission prompt on first launch** — User must click "Always Allow" or gets prompted every 2 minutes
4. **Clock skew** — Token expiry computed from `Date()`. If the user's system clock is significantly wrong, proactive refresh may fire too early or too late
5. **`unsafeFlags` in `Package.swift`** — Package cannot be consumed as a dependency (fine for standalone app)
6. **Sequoia Gatekeeper** — On macOS 15+, `xattr -cr` is no longer sufficient; users must manually allow in System Settings
7. **Refresh token crash window** — If the app crashes in the microseconds between receiving a refresh response and storing it in memory, the token is lost. Recovery: run `claude login`

---

## Requirements

- **macOS 14 Sonoma or later** (for `@Observable`, `MenuBarExtra` `.window` style)
- **Swift 6.0+** toolchain (comes with Xcode 16+ or swift.org toolchain)
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

On first launch:
1. **macOS 15 (Sequoia):** Go to System Settings → Privacy & Security → click "Open Anyway"
2. **Keychain dialog:** Click **"Always Allow"** (not just "Allow") when macOS asks about keychain access
3. The menu bar icon appears showing your current 5-hour usage percentage

To auto-start on login: System Settings → General → Login Items → add `ClaudeUsage.app`.
