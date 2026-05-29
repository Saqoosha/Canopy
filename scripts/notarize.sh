#!/usr/bin/env bash
set -euo pipefail

# Configuration
DEVELOPER_ID="Developer ID Application: Tomohiko Koyama (VCFY2GFR89)"
TEAM_ID="VCFY2GFR89"
KEYCHAIN_PROFILE="notarytool-profile"

APP_PATH="$1"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: App not found at $APP_PATH"
  exit 1
fi

APP_NAME=$(basename "$APP_PATH" .app)
WORK_DIR=$(dirname "$APP_PATH")
ZIP_PATH="${WORK_DIR}/${APP_NAME}.zip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="${SCRIPT_DIR}/../Sources/Canopy/Canopy.entitlements"

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "Error: Entitlements file not found at $ENTITLEMENTS"
  exit 1
fi

echo "=== Signing $APP_NAME.app ==="

# Sign all nested executables, frameworks, and libraries first (inside-out).
# codesign requires nested code to be sealed before the outer bundle. We
# intentionally don't pass --entitlements here: entitlements are baked into
# each binary at sign time (NOT inherited from the host at runtime), and
# nested helpers currently have no sandbox/TCC scopes of their own. If a
# future helper ever needs e.g. camera/mic, sign it with its own entitlements.
find "$APP_PATH" -type f \( -perm +111 -o -name "*.dylib" \) ! -path "*/MacOS/${APP_NAME}" | while read -r item; do
  echo "  Signing nested: $(basename "$item") ($(dirname "$item" | sed "s|.*\.app/||"))"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$item"
done

# Sign the main app bundle last with --entitlements. codesign --force without
# --entitlements replaces the embedded entitlements blob with an empty one,
# dropping the camera/microphone/etc. scopes Xcode put there during build.
# Result: TCC silently denies access (no permission prompt) for the app and
# for any subprocess that walks back to it as the responsible process.
echo "  Signing app bundle: $APP_NAME.app"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID" "$APP_PATH"

# Verify signature
codesign --verify --deep --verbose "$APP_PATH"
echo "Signature verified."

# Sanity-check that --entitlements actually made it into the signed bundle.
# codesign --verify only checks signature integrity, not entitlement payload —
# so without this assertion a regression that strips entitlements again would
# ship silently and only surface when a user hits a TCC-gated subsystem.
KEY_ENTITLEMENT="com.apple.security.device.camera"
if ! codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q "$KEY_ENTITLEMENT"; then
  echo "Error: expected entitlement '$KEY_ENTITLEMENT' missing from signed bundle"
  exit 1
fi
echo "Entitlements verified."

echo "=== Creating ZIP for notarization ==="
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "=== Submitting for notarization ==="
# Note: First time setup requires:
# xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" --apple-id YOUR_APPLE_ID --team-id $TEAM_ID --password APP_SPECIFIC_PASSWORD

xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo "=== Stapling notarization ticket ==="
xcrun stapler staple "$APP_PATH"

# Verify stapled ticket
xcrun stapler validate "$APP_PATH"

# Clean up
rm -f "$ZIP_PATH"

echo "=== Notarization complete ==="
echo "$APP_PATH"
