#!/usr/bin/env bash
set -euo pipefail

# Configuration
DEVELOPER_ID="Developer ID Application: Whatever Co. (G5G54TCH8W)"
TEAM_ID="G5G54TCH8W"
KEYCHAIN_PROFILE="notarytool-profile"

APP_PATH="$1"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: App not found at $APP_PATH"
  exit 1
fi

APP_NAME=$(basename "$APP_PATH" .app)
WORK_DIR=$(dirname "$APP_PATH")
ZIP_PATH="${WORK_DIR}/${APP_NAME}.zip"

echo "=== Signing $APP_NAME.app ==="

# Sign all nested executables, frameworks, and libraries first (inside-out)
find "$APP_PATH" -type f \( -perm +111 -o -name "*.dylib" \) ! -path "*/MacOS/${APP_NAME}" | while read -r item; do
  echo "  Signing nested: $(basename "$item") ($(dirname "$item" | sed "s|.*\.app/||"))"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$item"
done

# Sign the main app bundle last
echo "  Signing app bundle: $APP_NAME.app"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP_PATH"

# Verify signature
codesign --verify --deep --verbose "$APP_PATH"
echo "Signature verified."

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
