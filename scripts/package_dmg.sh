#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"

APP_NAME="Canopy"
VOL_NAME="Canopy"

# Read version from project.yml
VERSION=$(grep 'MARKETING_VERSION:' "${ROOT_DIR}/project.yml" | sed 's/.*: *"\(.*\)".*/\1/')
DMG_NAME="Canopy-${VERSION}"

DMG_ROOT="${BUILD_DIR}/dmg-root"
OUT_DMG="${BUILD_DIR}/${DMG_NAME}.dmg"

DEVELOPER_ID="Developer ID Application: Whatever Co. (G5G54TCH8W)"
KEYCHAIN_PROFILE="notarytool-profile"

rm -rf "${DMG_ROOT}"
mkdir -p "${DMG_ROOT}"

echo "=== Building Release ==="
"${ROOT_DIR}/scripts/build.sh" Release

APP_PATH="${BUILD_DIR}/Build/Products/Release/${APP_NAME}.app"

echo "=== Notarizing app ==="
"${ROOT_DIR}/scripts/notarize.sh" "${APP_PATH}"

cp -R "${APP_PATH}" "${DMG_ROOT}/"
# Strip code-signed xattrs from shell scripts — Sparkle can't create binary deltas when
# files have code-signing xattrs (com.apple.cs.*). File-content hashes in CodeResources
# are unaffected, so the bundle signature remains valid.
find "${DMG_ROOT}" -name "*.sh" -exec xattr -c {} \;
ln -s /Applications "${DMG_ROOT}/Applications"

echo "=== Creating DMG ==="
rm -f "${OUT_DMG}"
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${OUT_DMG}"

echo "=== Notarizing DMG ==="
codesign --force --sign "$DEVELOPER_ID" "${OUT_DMG}"

xcrun notarytool submit "${OUT_DMG}" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

xcrun stapler staple "${OUT_DMG}"

echo "=== Done ==="
echo "Created notarized DMG:"
echo "${OUT_DMG}"
