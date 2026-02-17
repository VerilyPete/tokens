# Claude Usage Menu Bar App — Implementation Plan

## Overview

A native macOS menu bar app built with Swift/SwiftUI that displays Claude Pro/Max subscription usage at a glance. Clicking the menu bar icon opens a popover showing 5-hour rolling, 7-day weekly, and per-model (Sonnet/Opus) usage with color-coded progress bars. It auto-refreshes every 2 minutes.

---

## Architecture

### Approach: SwiftUI `MenuBarExtra` (macOS 13+)

- **No Xcode required to build** — uses Swift Package Manager + a `build.sh` script
- The build script compiles via `swift build` and packages the result into a proper `.app` bundle
- `Info.plist` sets `LSUIElement = YES` so the app has no Dock icon — menu bar only
- The menu bar shows the current 5-hour utilization as a text percentage (e.g. `37%`) that updates live
- Clicking it opens a `.window`-style popover with full usage details

### API Details

| Detail | Value |
|---|---|
| **Endpoint** | `GET https://api.anthropic.com/api/oauth/usage` |
| **Auth header** | `Authorization: Bearer <accessToken>` |
| **Beta header** | `anthropic-beta: oauth-2025-04-20` |
| **Poll interval** | Every 120 seconds |

### API Response Shape

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

### Token Retrieval (macOS Keychain)

Claude Code stores OAuth credentials in the macOS Keychain under service name `"Claude Code-credentials"`. Retrieved via:

```bash
security find-generic-password -s "Claude Code-credentials" -w
```

This returns JSON containing:

```json
{
  "claudeAiOauth": {
    "accessToken": "...",
    "refreshToken": "...",
    "expiresAt": 1234567890,
    "scopes": ["user:inference", "user:profile"]
  }
}
```

### Token Refresh

When the access token expires, refresh via:

```
POST https://api.anthropic.com/v1/oauth/token
Content-Type: application/json

{
  "grant_type": "refresh_token",
  "refresh_token": "<refreshToken>",
  "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
}
```

**Important:** Refresh tokens are single-use. The new access token and refresh token from the response must be saved back.

---

## File Structure

```
tokens/
├── LICENSE
├── PLAN.md                             ← this file
├── Package.swift                       # Swift Package Manager manifest
├── build.sh                            # Build + .app bundle creation script
├── Resources/
│   └── Info.plist                      # LSUIElement = YES (no dock icon)
└── Sources/
    └── ClaudeUsage/
        ├── ClaudeUsageApp.swift         # @main App with MenuBarExtra
        ├── ContentView.swift            # Popover UI: all usage metrics
        ├── Models.swift                 # Codable structs for API response
        ├── KeychainHelper.swift         # Read/write OAuth token via Security framework
        ├── UsageService.swift           # API client, polling timer, token refresh
        └── UsageBarView.swift           # Reusable color-coded progress bar
```

**6 Swift source files, 1 Package.swift, 1 build script, 1 Info.plist** — compact and focused.

---

## Implementation Steps

### Step 1: `Package.swift`

Swift Package Manager manifest targeting macOS 13+ with a single executable target (`ClaudeUsage`). Links against `SwiftUI`, `AppKit`, and `Security` frameworks.

### Step 2: `Resources/Info.plist`

Minimal plist with:
- `LSUIElement` = `true` (hides from Dock, menu-bar-only app)
- `CFBundleName` = `ClaudeUsage`
- `CFBundleIdentifier` = `com.tokens.claude-usage`

### Step 3: `Sources/ClaudeUsage/Models.swift`

Codable structs mirroring the API response:

- `UsageResponse` — top-level with `fiveHour`, `sevenDay`, `sevenDayOpus?`, `sevenDaySonnet?`, `extraUsage?`
- `UsageBucket` — contains `utilization: Double` and `resetsAt: String`
- `ExtraUsage` — contains `isEnabled: Bool`, optional limit/credits/utilization

Uses `CodingKeys` with `snake_case` → `camelCase` mapping.

### Step 4: `Sources/ClaudeUsage/KeychainHelper.swift`

Uses the macOS Security framework (`SecItemCopyMatching`) to:
1. Query the Keychain for service `"Claude Code-credentials"`
2. Parse the returned JSON to extract `claudeAiOauth.accessToken` and `claudeAiOauth.refreshToken`
3. Also provide a `saveToken()` method for writing refreshed tokens back

Fallback: if Security framework access fails (e.g. permissions), shell out to `security find-generic-password -s "Claude Code-credentials" -w` via `Process`.

### Step 5: `Sources/ClaudeUsage/UsageService.swift`

An `@Observable` class (or `ObservableObject` with `@Published`) that:
1. Holds the current `UsageResponse?` and error state
2. Runs a `Timer` every 120 seconds to poll the API
3. Uses `URLSession` to `GET` the usage endpoint with proper headers
4. On 401 response → attempts token refresh, retries once
5. Token refresh: `POST /v1/oauth/token` with refresh token, saves new tokens via `KeychainHelper`
6. Exposes computed properties like `fiveHourPercent`, `sevenDayPercent`, `sonnetPercent`, etc.

### Step 6: `Sources/ClaudeUsage/UsageBarView.swift`

A reusable SwiftUI view that renders a horizontal progress bar:
- Takes `label: String`, `percentage: Double`, `resetsAt: String?`
- Color-coded: green (0–50%), yellow (50–80%), red (80–100%)
- Shows "Resets in X hr Y min" computed from the `resetsAt` ISO 8601 timestamp
- Clean, minimal design with rounded corners

### Step 7: `Sources/ClaudeUsage/ContentView.swift`

The main popover view containing:
- A header row with the app name and a refresh button
- `UsageBarView` for **5-Hour Rolling** usage
- `UsageBarView` for **7-Day Weekly** usage
- Conditional `UsageBarView` for **Sonnet (7-Day)** if present
- Conditional `UsageBarView` for **Opus (7-Day)** if present
- An info section for **Extra Usage** if enabled
- A "Last updated" timestamp at the bottom
- An error banner if the API call fails (with retry button)
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
            Text("\(Int(usageService.fiveHourPercent))%")
        }
        .menuBarExtraStyle(.window)
    }
}
```

- Menu bar shows live 5-hour percentage as text
- `.window` style gives a proper popover (not just a menu)
- `usageService` is created once and shared

### Step 9: `build.sh`

A shell script that:
1. Runs `swift build -c release`
2. Creates `ClaudeUsage.app/Contents/MacOS/` and `ClaudeUsage.app/Contents/`
3. Copies the built binary into `MacOS/`
4. Copies `Info.plist` into `Contents/`
5. Optionally copies to `/Applications/` or `~/Applications/`
6. Prints instructions for first-time launch (Gatekeeper)

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
│  5-Hour Rolling                 │
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

## Requirements

- **macOS 13 Ventura or later** (for `MenuBarExtra`)
- **Swift 5.9+** (for `@Observable` macro; or 5.7+ with `ObservableObject`)
- **Claude Code** installed and logged in (so the OAuth token is in Keychain)
- No Xcode IDE needed — builds from the terminal with `swift build`

## User Workflow

```bash
git clone <this-repo>
cd tokens
chmod +x build.sh
./build.sh                    # Compiles + creates ClaudeUsage.app
open ClaudeUsage.app          # Launches in menu bar
```

To auto-start on login: System Settings → General → Login Items → add `ClaudeUsage.app`.
