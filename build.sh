#!/bin/bash
set -euo pipefail

# Claude Usage Menu Bar App — Build Script
# Compiles via SPM, packages into .app bundle, and ad-hoc codesigns.

APP_NAME="ClaudeUsage"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "=== Claude Usage Build Script ==="

# Step 1: Check Swift version (require 6.0+)
SWIFT_VERSION=$(swift --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' || echo "0.0")
SWIFT_MAJOR=$(echo "$SWIFT_VERSION" | cut -d. -f1)

if [ "$SWIFT_MAJOR" -lt 6 ]; then
    echo "ERROR: Swift 6.0+ required (found Swift $SWIFT_VERSION)"
    echo "Install Xcode 16+ or download from https://swift.org"
    exit 1
fi
echo "Swift version: $SWIFT_VERSION"

# Step 2: Build release
echo "Building ${APP_NAME}..."
swift build -c release

# Step 3: Create .app bundle structure
echo "Creating ${APP_BUNDLE}..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"

# Step 4: Copy binary and Info.plist
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/"

# Step 5: Ad-hoc codesign
echo "Codesigning..."
codesign --sign - "${APP_BUNDLE}"

echo ""
echo "=== Build Complete ==="
echo "Output: ${APP_BUNDLE}"
echo ""
echo "--- First-time launch instructions ---"
echo ""
echo "macOS 14 (Sonoma):"
echo "  If blocked by Gatekeeper: xattr -cr ${APP_BUNDLE}"
echo ""
echo "macOS 15+ (Sequoia):"
echo "  System Settings > Privacy & Security > click 'Open Anyway'"
echo ""
echo "Keychain access:"
echo "  On first launch, click 'Always Allow' when macOS asks about"
echo "  keychain access (not just 'Allow')."
echo ""
echo "Auto-start on login:"
echo "  System Settings > General > Login Items > add ${APP_BUNDLE}"
