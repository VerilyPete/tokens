# Code Signing & Notarization Plan for GitHub Actions

## Overview

Replace the current ad-hoc signing (`codesign --sign -`) with proper Apple Developer ID signing and notarization in the CI pipeline. This enables users to run the app without Gatekeeper workarounds.

---

## Prerequisites (One-Time Manual Setup)

### 1. Export Developer ID Certificate as .p12

On your Mac with the Developer ID certificate installed:

1. Open **Keychain Access** → "login" keychain → "My Certificates"
2. Find **"Developer ID Application: Your Name (TEAM_ID)"**
3. Right-click → "Export Items..." → save as `.p12` with a strong password
4. Base64-encode it:
   ```bash
   base64 -i DeveloperIDApplication.p12 | pbcopy
   ```

### 2. Create App Store Connect API Key (for notarization)

1. Go to [App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys](https://appstoreconnect.apple.com/access/integrations/api)
2. Create a new key with **Developer** role (minimum for notarization)
3. Download the `.p8` file (one-time download only)
4. Note the **Key ID** (10-char alphanumeric) and **Issuer ID** (UUID, shown at top of page)
5. Base64-encode the .p8:
   ```bash
   base64 -i AuthKey_XXXXXXXX.p8 | pbcopy
   ```

**Important:** Must be a **Team Key**, not a Personal Key — personal keys cannot notarize.

### 3. Create GitHub Secrets

In the repo: Settings → Secrets and variables → Actions → New repository secret

| Secret | Value |
|---|---|
| `DEVELOPER_CERT_BASE64` | Base64-encoded .p12 certificate + private key |
| `DEVELOPER_CERT_PASSWORD` | Password used when exporting .p12 |
| `DEVELOPER_SIGNING_IDENTITY` | Full identity, e.g. `Developer ID Application: Peter Hollmer (K1234567)` |
| `KEYCHAIN_PASSWORD` | Any strong random string (for temporary CI keychain) |
| `APPSTORE_KEY_BASE64` | Base64-encoded .p8 API key file |
| `APPSTORE_KEY_ID` | App Store Connect API Key ID |
| `APPSTORE_ISSUER_ID` | App Store Connect API Issuer ID |

### 4. Add Missing Keys to Info.plist

Add the following keys to `Resources/Info.plist` (best practice for proper code signing; macOS can infer these for ad-hoc but Developer ID signing and Gatekeeper are stricter):

```xml
<key>CFBundleExecutable</key>
<string>ClaudeUsage</string>
<key>CFBundlePackageType</key>
<string>APPL</string>
```

---

## Implementation Changes

### Change 1: Modify `build.sh` to Accept Signing Identity

Replace the hardcoded ad-hoc signing with a parameterized identity. The script should accept optional `--sign` and `--entitlements` arguments, defaulting to ad-hoc for local builds.

**Place the argument parser after the variable declarations (line 9) but before Step 1 (Swift version check, line 13):**

```bash
# Parse arguments
SIGN_IDENTITY="-"  # default: ad-hoc
ENTITLEMENTS_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --sign)
            # [Updated: actual implementation adds argument validation guards]
            if [[ $# -lt 2 ]]; then echo "ERROR: --sign requires an argument"; exit 1; fi
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        --entitlements)
            # [Updated: actual implementation adds argument validation guards]
            if [[ $# -lt 2 ]]; then echo "ERROR: --entitlements requires an argument"; exit 1; fi
            ENTITLEMENTS_ARGS=(--entitlements "$2")
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done
```

Replace the codesign step (current line 39: `codesign --sign - "${APP_BUNDLE}"`):

```bash
# Step 5: Codesign
echo "Codesigning with identity: ${SIGN_IDENTITY}..."
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --sign - "${APP_BUNDLE}"
else
    codesign \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --timestamp \
        ${ENTITLEMENTS_ARGS[@]+"${ENTITLEMENTS_ARGS[@]}"} \ # [Updated: uses ${arr[@]+"${arr[@]}"} pattern instead of bare "${arr[@]}" — safer under set -u when array is empty, because bash 4.x (macOS default) treats an empty array expansion as "unbound variable"]
        "${APP_BUNDLE}"
fi
```

**Notes:**
- Uses a bash array (`ENTITLEMENTS_ARGS`) instead of string interpolation to correctly handle paths with spaces.
- `ENTITLEMENTS_ARGS=()` is initialized empty so `set -u` (from `set -euo pipefail`) does not trigger an unbound variable error. **[Updated: the actual expansion uses `${ENTITLEMENTS_ARGS[@]+"${ENTITLEMENTS_ARGS[@]}"}` — the `+` operator provides an additional safeguard under bash 4.x, where `"${arr[@]}"` on an empty array triggers unbound-variable errors despite the initialization.]**
- `--force` is omitted because `build.sh` creates a fresh bundle (`rm -rf`) so re-signing is unnecessary.
- Supports `--` as end-of-options marker.

**Local usage stays the same:** `./build.sh`
**CI usage:** `./build.sh --sign "Developer ID Application: ..."`

### Change 2: Update `.github/workflows/ci.yml`

Replace the current workflow with a pipeline that has separate jobs for building/testing (runs on all pushes/PRs) and signing/notarizing (runs only on main):

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: macos-15
    timeout-minutes: 15

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          persist-credentials: false  # **[Updated]** Added as later security hardening — prevents the GITHUB_TOKEN from persisting in the local git config, reducing the attack surface if a subsequent step is compromised.

      - name: Cache SPM dependencies
        uses: actions/cache@v4
        with:
          path: |
            .build
            ~/Library/Caches/org.swift.swiftpm
            ~/Library/org.swift.swiftpm
          key: macos-spm-${{ hashFiles('Package.swift', 'Package.resolved') }}
          restore-keys: macos-spm-

      - name: Build (debug)
        run: swift build

      - name: Test
        run: swift test
        timeout-minutes: 10

      - name: Build release and package .app bundle
        run: ./build.sh

      - name: Upload .app artifact
        uses: actions/upload-artifact@v4
        with:
          name: ClaudeUsage.app
          path: ClaudeUsage.app/
          retention-days: 7

  sign-and-notarize:
    needs: build-and-test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: macos-15
    timeout-minutes: 30

    steps:
      - name: Check signing secrets
        env:
          DEVELOPER_CERT_BASE64: ${{ secrets.DEVELOPER_CERT_BASE64 }}
        run: |
          if [ -z "$DEVELOPER_CERT_BASE64" ]; then
            echo "::notice::Signing secrets not configured — skipping sign-and-notarize job"
            echo "See plans/SIGNING_PLAN.md for setup instructions"
            exit 1
          fi

      - name: Checkout
        uses: actions/checkout@v4
        with:
          persist-credentials: false  # **[Updated]** Same security hardening as build-and-test checkout.

      - name: Cache SPM dependencies
        uses: actions/cache@v4
        with:
          path: |
            .build
            ~/Library/Caches/org.swift.swiftpm
            ~/Library/org.swift.swiftpm
          key: macos-spm-${{ hashFiles('Package.swift', 'Package.resolved') }}
          restore-keys: macos-spm-

      - name: Import code signing certificate
        env:
          DEVELOPER_CERT_BASE64: ${{ secrets.DEVELOPER_CERT_BASE64 }}
          DEVELOPER_CERT_PASSWORD: ${{ secrets.DEVELOPER_CERT_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          CERT_PATH="$RUNNER_TEMP/developer_cert.p12"
          KEYCHAIN_PATH="$RUNNER_TEMP/app-signing.keychain-db"
          echo -n "$DEVELOPER_CERT_BASE64" | base64 --decode -o "$CERT_PATH"

          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

          security import "$CERT_PATH" \
            -P "$DEVELOPER_CERT_PASSWORD" \
            -A -t cert -f pkcs12 \
            -k "$KEYCHAIN_PATH"

          # Critical: allow codesign to access key without UI prompt
          security set-key-partition-list \
            -S apple-tool:,apple:,codesign: \
            -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

          # Add to search list while preserving existing keychains
          security list-keychains -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | tr -d '"')

      - name: Build release and sign
        env:
          DEVELOPER_SIGNING_IDENTITY: ${{ secrets.DEVELOPER_SIGNING_IDENTITY }}
        run: |
          ./build.sh --sign "$DEVELOPER_SIGNING_IDENTITY"

      - name: Verify signature
        run: |
          codesign --verify --deep --strict -vvvv ClaudeUsage.app
          echo "Signature verified successfully"

      - name: Notarize
        env:
          APPSTORE_KEY_BASE64: ${{ secrets.APPSTORE_KEY_BASE64 }}
          APPSTORE_KEY_ID: ${{ secrets.APPSTORE_KEY_ID }}
          APPSTORE_ISSUER_ID: ${{ secrets.APPSTORE_ISSUER_ID }}
        run: |
          # Decode API key
          API_KEY_PATH="$RUNNER_TEMP/AuthKey.p8"
          echo -n "$APPSTORE_KEY_BASE64" | base64 --decode -o "$API_KEY_PATH"

          # Create zip with ditto (NOT zip — zip corrupts macOS metadata)
          ditto -c -k --sequesterRsrc --keepParent ClaudeUsage.app ClaudeUsage.zip

          # Submit and wait for Apple to process (typically 2-15 min)
          # Use --output-format json for reliable status parsing
          # Use --timeout to exit gracefully before runner kills the job
          # Capture stdout (JSON) separately from stderr (progress/diagnostics)
          NOTARY_OUTPUT=$(xcrun notarytool submit ClaudeUsage.zip \
            --key "$API_KEY_PATH" \
            --key-id "$APPSTORE_KEY_ID" \
            --issuer "$APPSTORE_ISSUER_ID" \
            --wait \
            --timeout 20m \
            --output-format json 2>"$RUNNER_TEMP/notary_stderr.log")

          echo "$NOTARY_OUTPUT"
          cat "$RUNNER_TEMP/notary_stderr.log" || true

          # Parse status — do not rely on exit code alone
          STATUS=$(echo "$NOTARY_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','Unknown'))")

          if [ "$STATUS" != "Accepted" ]; then
              echo "ERROR: Notarization failed with status: $STATUS"
              SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
              if [ -n "$SUBMISSION_ID" ]; then
                  echo "--- Notarization log ---"
                  xcrun notarytool log "$SUBMISSION_ID" \
                      --key "$API_KEY_PATH" \
                      --key-id "$APPSTORE_KEY_ID" \
                      --issuer "$APPSTORE_ISSUER_ID"
              fi
              exit 1
          fi

          # Staple the ticket to the .app (NOT the zip)
          xcrun stapler staple ClaudeUsage.app

      - name: Verify notarization
        run: |
          xcrun stapler validate ClaudeUsage.app
          spctl -a -vvv -t execute ClaudeUsage.app

      - name: Package signed app
        run: |
          # **[Updated]** Added this step. `actions/upload-artifact` internally re-zips using a method
          # that strips macOS extended attributes (resource forks, quarantine bits), which invalidates
          # code signatures. Using `ditto` to create a zip first preserves all metadata, then the
          # artifact upload just wraps an already-correct zip.
          ditto -c -k --sequesterRsrc --keepParent ClaudeUsage.app ClaudeUsage-signed.zip

      - name: Upload signed app
        uses: actions/upload-artifact@v4
        with:
          name: ClaudeUsage-signed  # **[Updated]** Was `ClaudeUsage-signed.app`. Changed to `ClaudeUsage-signed` because the artifact is now a zip file, not a raw .app directory.
          path: ClaudeUsage-signed.zip  # **[Updated]** Was `ClaudeUsage.app/` (raw directory). Now uploads the pre-zipped file to preserve code signature integrity (see Package step above).
          retention-days: 30

      - name: Clean up signing artifacts
        if: ${{ always() }}
        run: |
          security delete-keychain "$RUNNER_TEMP/app-signing.keychain-db" || true
          rm -f "$RUNNER_TEMP/developer_cert.p12"
          rm -f "$RUNNER_TEMP/AuthKey.p8"
```

---

## Entitlements

**No entitlements file is needed.** The app's three capabilities are all allowed by default under hardened runtime:

- **URLSession (HTTPS)** — outbound networking is unrestricted for non-sandboxed apps
- **`/usr/bin/security` subprocess** — launching signed system binaries is allowed
- **os.Logger** — standard system API, no restrictions

If entitlements are ever needed in the future, create `Resources/ClaudeUsage.entitlements` and pass `--entitlements Resources/ClaudeUsage.entitlements` to `build.sh`.

---

## Key Design Decisions

1. **Two-job pipeline** **[Updated: now a three-job pipeline after RELEASE_PLAN.md added a `release` job]**: `build-and-test` runs on all pushes/PRs (fast feedback, uploads unsigned artifact for testing); `sign-and-notarize` runs only on main pushes (avoids burning signing resources on PRs and avoids needing secrets in PR workflows from forks); `release` runs on GitHub Release events (stamps version, builds, signs, notarizes, uploads zip + checksum to the release).

2. **No `--deep` flag for signing**: Deprecated since macOS 13 and causes problems when *signing*. Since this app has no nested frameworks or helpers, a single `codesign` on the .app bundle is sufficient. **[Updated]** Clarified that this guidance applies to signing only. The *verification* steps (`codesign --verify --deep --strict`) do use `--deep` because it is harmless and conventional there -- it tells `codesign` to recursively verify nested code, which is a read-only check. The deprecation concerns apply to `codesign --sign --deep`, which would recursively re-sign nested bundles in an uncontrolled order.

3. **`ditto` for zip creation**: Standard `zip` corrupts macOS resource forks and causes "Invalid signature" notarization failures.

4. **App Store Connect API key auth** (not Apple ID): No 2FA required, purpose-built for CI, least-privilege with Developer role.

5. **Ad-hoc default preserved**: `build.sh` without arguments still does ad-hoc signing for local development. No change in local workflow.

6. **30-day artifact retention** for signed builds (vs 7-day for unsigned PR builds).

7. **Explicit notarization status parsing**: Uses `--output-format json` and parses the `status` field rather than relying on `notarytool` exit codes, which are unreliable across Xcode versions. On failure, automatically fetches and prints the notarization log for diagnostics.

8. **Keychain search list preserved**: Uses `security list-keychains` to append the temporary keychain rather than replacing the search list, making the workflow safe for both hosted and self-hosted runners.

---

## Gotchas to Watch For

- **`get-task-allow` entitlement**: Must NOT be present — causes instant notarization rejection. Not an issue here since we're not using Xcode and never add debug entitlements.
- **Timestamp server outage**: `--timestamp` contacts Apple's servers; transient failures may require retry. If this becomes a recurring issue in CI, wrap the codesign step in a retry loop (1-2 retries with 10s backoff).
- **No provisioning profile needed**: Developer ID distribution outside the App Store does not require a provisioning profile.
- **macOS-specific `base64` flags**: The `base64 --decode -o` syntax is BSD/macOS-specific. The workflow assumes `macos-15` runners. If ever ported to Linux runners, use `base64 -d > file` instead.

---

## Order of Operations Summary

1. Add `CFBundleExecutable` and `CFBundlePackageType` to `Resources/Info.plist` (one-time)
2. Create secrets in GitHub repo settings (one-time)
3. Modify `build.sh` to accept `--sign` and `--entitlements` flags
4. Update `ci.yml` with the two-job pipeline **[Updated: now three-job after RELEASE_PLAN.md]**
5. Push to main → CI builds, tests, signs, notarizes, uploads signed artifact
6. Download the signed `.app` from GitHub Actions artifacts — no more Gatekeeper workarounds
