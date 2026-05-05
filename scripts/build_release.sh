#!/bin/bash

# Build and Release Script for MeetMemo
# This script builds the app and creates a notarized DMG

set -e  # Exit on any error

# Configuration
APP_NAME="MeetMemo"
VERSION=$(grep -m1 "MARKETING_VERSION" MeetMemo.xcodeproj/project.pbxproj | sed 's/.*= \(.*\);/\1/')

# Source environment variables if .env file exists
if [ -f ".env" ]; then
    echo "📄 Loading environment variables from .env file..."
    source .env
fi

# Production code signing configuration
DEVELOPER_ID="${DEVELOPER_ID:-}"

# Notarization configuration (required for production builds)
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="${TEAM_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"

if [ -z "$VERSION" ]; then
    echo "❌ Could not determine version from project file"
    echo "   Make sure MeetMemo.xcodeproj/project.pbxproj exists and contains MARKETING_VERSION"
    exit 1
fi

for required_tool in xcodebuild codesign xcrun create-dmg; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        echo "❌ Missing required tool: $required_tool"
        echo "   Install it or make sure it is available in PATH before running this script."
        exit 1
    fi
done

BUILD_DIR="$(pwd)/build"
RELEASES_DIR="$(pwd)/releases"
# Keep each release in its own sub-folder (e.g. releases/v0.12)
VERSION_DIR="${RELEASES_DIR}/v${VERSION}"
mkdir -p "$VERSION_DIR"

DMG_NAME="${APP_NAME}.dmg"
# Absolute paths for the artifacts
DMG_PATH="${VERSION_DIR}/${DMG_NAME}"

echo "🚀 Building ${APP_NAME} v${VERSION}..."

# Check signing configuration
echo "🔏 Using Developer ID Application: $DEVELOPER_ID"

# Verify notarization credentials
if [ -z "$DEVELOPER_ID" ] || [ -z "$APPLE_ID" ] || [ -z "$TEAM_ID" ] || [ -z "$APP_PASSWORD" ]; then
    echo "❌ Missing required credentials!"
    echo ""
    echo "📝 Required environment variables:"
    echo "   DEVELOPER_ID   - Your Developer ID Application certificate name"
    echo "   APPLE_ID       - Your Apple ID email"
    echo "   TEAM_ID        - Your Apple Developer Team ID"
    echo "   APP_PASSWORD   - App-specific password"
    echo ""
    echo "🔧 Set them up:"
    echo "   Create a .env file with your credentials"
    echo "   Then run: ./scripts/build_release.sh"
    echo ""
    echo "💡 Use: ./scripts/setup_codesigning.sh to get started"
    echo ""
    exit 1
fi

echo "📡 Notarization configured for Apple ID: $APPLE_ID"
echo "🏷️  Team ID: $TEAM_ID"

# Clean and build a *universal* binary (arm64 + x86_64)
# -----------------------------------------------------
# Xcode will only build the active architecture by default ("My Mac") which results in an
# Apple-silicon-only binary when run on an M-series machine. By explicitly passing both
# architectures and using the generic macOS destination we ensure a universal build.
# The resulting binary is produced at the usual DerivedData location so the rest of the
# script can continue to reference $APP_PATH unchanged.

ARCHS="arm64 x86_64"

echo "📦 Building universal app (archs: $ARCHS)..."
xcodebuild \
  -project MeetMemo.xcodeproj \
  -scheme MeetMemo \
  -configuration Release \
  -derivedDataPath "${BUILD_DIR}" \
  -destination 'generic/platform=macOS' \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  clean build

# Find the built app
APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ App not found at $APP_PATH"
    exit 1
fi

# 🔏 Production code signing with hardened runtime -------------------------------------------------

echo "🔏 Code signing all embedded frameworks and components..."

# Sign all embedded frameworks and their components first
# This is required for notarization - we must sign from the inside out
find "$APP_PATH" -name "*.framework" -type d | while read framework; do
    echo "   Signing framework: $(basename "$framework")"
    
    # Sign all binaries within the framework
    find "$framework" -type f -perm +111 -exec sh -c 'file "$1" | grep -q "Mach-O"' _ {} \; -print | while read binary; do
        echo "      Signing binary: $(basename "$binary")"
        codesign \
          --force \
          --options runtime \
          --sign "$DEVELOPER_ID" \
          --timestamp \
          "$binary"
    done
    
    # Sign the framework itself
    codesign \
      --force \
      --options runtime \
      --sign "$DEVELOPER_ID" \
      --timestamp \
      "$framework"
done

# Sign all XPC services
find "$APP_PATH" -name "*.xpc" -type d | while read xpc; do
    echo "   Signing XPC service: $(basename "$xpc")"
    codesign \
      --force \
      --options runtime \
      --sign "$DEVELOPER_ID" \
      --timestamp \
      "$xpc"
done

# Sign all nested apps
find "$APP_PATH" -name "*.app" -type d | grep -v "^$APP_PATH$" | while read app; do
    echo "   Signing nested app: $(basename "$app")"
    codesign \
      --force \
      --options runtime \
      --sign "$DEVELOPER_ID" \
      --timestamp \
      "$app"
done

echo "🔏 Code signing the main app with hardened runtime..."
codesign \
  --force \
  --options runtime \
  --entitlements "MeetMemo/MeetMemo.entitlements" \
  --sign "$DEVELOPER_ID" \
  --timestamp \
  "$APP_PATH"

# Validate the signature before packaging
echo "✅ Validating code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "✅ App built and signed successfully at $APP_PATH"

# Create DMG
echo "📀 Creating DMG..."
# Remove old DMG if it exists
if [ -f "$DMG_PATH" ]; then
    rm "$DMG_PATH"
fi

# Create DMG using create-dmg
create-dmg \
    --volname "$APP_NAME" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 200 190 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 600 185 \
    "$DMG_PATH" \
    "$APP_PATH"

echo "✅ DMG created: $DMG_PATH"

# 📡 Notarization (required for all production builds)
echo "📡 Starting notarization process..."

# Submit for notarization
echo "📤 Submitting DMG for notarization..."
NOTARIZATION_RESPONSE=$(xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait)

if echo "$NOTARIZATION_RESPONSE" | grep -q "status: Accepted"; then
    echo "✅ Notarization successful!"
    
    # Staple the notarization
    echo "📎 Stapling notarization ticket to DMG..."
    xcrun stapler staple "$DMG_PATH"
    echo "✅ DMG notarized and stapled!"
else
    echo "❌ Notarization failed!"
    echo "$NOTARIZATION_RESPONSE"
    exit 1
fi

# Show file sizes
echo ""
echo "📊 Release Summary:"
echo "   Version: $VERSION"
echo "   DMG: $DMG_NAME ($(du -h "$DMG_PATH" | cut -f1))"
echo "   Location: $VERSION_DIR"
echo "   Code Signing: ✅ Production (production Developer ID)"
echo "   Notarization (DMG): ✅ Complete"
echo ""
echo "🎉 Production release ready! Next steps:"
echo "   1. Test the DMG on another Mac"
echo "   2. Create a GitHub release with tag v${VERSION}"
echo "   3. Upload the DMG to the GitHub release"
