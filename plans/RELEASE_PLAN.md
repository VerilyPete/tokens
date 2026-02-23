# Plan: Release workflow + Launch at Login toggle

## Context

CI currently builds, tests, signs, and notarizes on every push to main, but artifacts expire after 30 days and there's no way to cut a versioned release. The app also has no way to auto-start on login. This plan adds two things:

1. A CI job that triggers on GitHub Release creation, stamps the version from the tag, builds/signs/notarizes, and attaches the `.zip` to the release as a permanent download.
2. An in-app "Launch at Login" toggle using `SMAppService`.

## Part 1: Release workflow

### Changes to `.github/workflows/ci.yml`

**Add `release` trigger** to the `on:` block:
```yaml
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  release:
    types: [published]
```

**Guard `build-and-test`** so it doesn't run redundantly on release events:
```yaml
build-and-test:
  if: github.event_name != 'release'
```

Note: the existing `sign-and-notarize` job already guards itself with `github.ref == 'refs/heads/main' && github.event_name == 'push'`, so it naturally won't run on release events. No changes needed there.

**Add a `release` job** (`if: github.event_name == 'release'`, `timeout-minutes: 45` **[Updated: actual uses `timeout-minutes: 30`, matching the sign-and-notarize job. 45 min was overly generous; notarization typically finishes in 20 min with a built-in `--timeout 20m`.]**, `permissions: contents: write`) that:

1. Validate the tag format with regex `^v[0-9]+\.[0-9]+\.[0-9]+$` (reject pre-release suffixes, since `CFBundleVersion` requires dot-separated integers):
   ```bash
   # [Updated: actual implementation validates TAG (not VERSION), uses a more descriptive error message,
   # and adds an explicit "CFBundleVersion requires dot-separated integers" explanation line]
   TAG="${GITHUB_REF_NAME}"
   if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
     echo "ERROR: Tag '$TAG' does not match required format v#.#.# (e.g. v1.2.3)"
     echo "CFBundleVersion requires dot-separated integers — pre-release suffixes are not allowed."
     exit 1
   fi
   ```
   **[Updated: all checkout steps in the actual workflow include `persist-credentials: false`, added as later security hardening to prevent the checked-out GITHUB_TOKEN from persisting in the git credential helper.]**
2. Cache SPM dependencies (same cache key as other jobs).
3. Stamp version into `Resources/Info.plist` using `/usr/libexec/PlistBuddy` (not `sed`, because PlistBuddy is plist-aware and doesn't depend on the current value):
   ```bash
   /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
   /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist
   ```
   This must happen before `swift build` because the `-sectcreate` linker flag in Package.swift embeds Info.plist into the binary at compile time. Both the embedded binary plist and the `Contents/Info.plist` copy (from build.sh) read from the same stamped source file, so versions stay consistent.
4. ~~Run `swift package clean` to ensure no cached build artifacts skip re-linking with the stamped plist.~~ **[Updated: dropped in actual implementation. CI builds start from a fresh checkout (or a clean cache restore), so there are no stale build artifacts that would skip re-linking with the stamped plist. The clean step was unnecessary overhead.]**
5. Run debug build + tests (defensive, since the tag points to code that already passed CI on main).
6. Import signing certificate (same steps as existing `sign-and-notarize` job; add sync comment pointing to the other job). **[Updated: the signing secrets check differs between jobs — `sign-and-notarize` uses `::notice::` and exits gracefully (secrets are optional for CI), while `release` uses `::error::` and fails hard (secrets are required to create a release). Both share the same certificate import steps after the check passes.]**
7. Build release + sign via `./build.sh --sign "$IDENTITY"`.
8. Verify signature.
9. Notarize + staple (same as existing job; add sync comment).
10. Verify notarization.
11. Create ditto zip as `ClaudeUsage-${GITHUB_REF_NAME}.zip`.
12. Generate SHA-256 checksum: `shasum -a 256 "ClaudeUsage-${GITHUB_REF_NAME}.zip" > "ClaudeUsage-${GITHUB_REF_NAME}.zip.sha256"`.
13. ~~Upload zip as GitHub Actions artifact (fallback in case `gh release upload` fails).~~ **[Updated: dropped in actual implementation. The artifact upload fallback was unnecessary — `gh release upload` with `--clobber` is reliable, and a failed upload would be caught by the job failure. Keeping a redundant artifact would also create confusion about which download is canonical.]**
14. Upload zip + checksum to the GitHub Release via `gh release upload "$GITHUB_REF_NAME" ... --clobber`.
15. Clean up signing artifacts.

The `release` job duplicates the signing/notarization steps from `sign-and-notarize`. A reusable workflow could eliminate the duplication, but for a workflow this size it's simpler to keep it inline with sync comments in both jobs. We can refactor later if the workflow grows.

**Add concurrency control** to prevent parallel release builds:
```yaml
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
```

### Files to modify

- `.github/workflows/ci.yml`

## Part 2: Launch at Login toggle

Add a toggle to the popover using `SMAppService.mainApp` from the `ServiceManagement` framework.

### Changes to `Sources/ClaudeUsage/ContentView.swift`

Add `import ServiceManagement` and `import os` at the top. Add a private logger **[Updated: actual implementation does not import `os` or use a private logger, since errors are surfaced to the user via an alert dialog rather than logged. Only `import ServiceManagement` was added.]**:
```swift
private let logger = Logger(subsystem: "com.tokens.claude-usage", category: "ContentView")
```

Add a "Launch at Login" checkbox toggle in the `footerRow` VStack, between the "Updated X ago" text and the "Reload Credentials" button.

The binding reads `SMAppService.mainApp.status` and calls `register()`/`unregister()` on toggle. Log errors via `os.Logger` instead of silently swallowing them **[Updated: actual implementation uses `@State private var loginItemError: String?` to surface errors to the user via a `.alert` dialog, rather than only logging them. This is more user-friendly — if registration fails (e.g., sandboxing issue), the user sees what went wrong instead of having the toggle silently snap back. The `os.Logger` + private logger constant were not needed and were omitted.]**:

```swift
import ServiceManagement

// [Updated: @State added to ContentView for error alert]
@State private var loginItemError: String?

// [Updated: .alert modifier added to the main VStack]
.alert("Launch at Login", isPresented: Binding(
    get: { loginItemError != nil },
    set: { if !$0 { loginItemError = nil } }
)) {
    Button("OK") { loginItemError = nil }
} message: {
    Text(loginItemError ?? "")
}

// In footerRow VStack:
Toggle("Launch at Login", isOn: Binding(
    get: { SMAppService.mainApp.status == .enabled },
    set: { newValue in
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
    }
))
.toggleStyle(.checkbox)
.font(.caption)
```

Notes:
- No new entitlements, no changes to Package.swift, no new dependencies.
- Works with both ad-hoc and Developer ID signing on macOS 14+.
- Works with `LSUIElement=true` (menu bar apps can register as login items).
- The app needs a valid `CFBundleIdentifier` (already has `com.tokens.claude-usage`).
- `SMAppService.mainApp.status` is read each time SwiftUI evaluates the view (on popover reopen), so it stays in sync with System Settings.

### Files to modify

- `Sources/ClaudeUsage/ContentView.swift`

## Verification

1. After implementing, run `swift build` and `swift test` to confirm nothing breaks.
2. For the Launch at Login toggle: run the app locally, toggle it on, verify it appears in System Settings > General > Login Items, toggle it off, verify it disappears.
3. For the release workflow: push to a branch, open a PR, confirm `build-and-test` runs normally. After merging, confirm `build-and-test` and `sign-and-notarize` run on the main push. Create a test release with tag `v1.0.1`, confirm the `release` job runs, stamps the version, and attaches the zip (this last step requires signing secrets to be configured).
