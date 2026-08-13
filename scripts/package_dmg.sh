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
# Create/sign/notarize/staple the DMG in /tmp, then copy the finished file
# into build/. Time Machine holds I/O locks on ~/Documents while backing up,
# which hangs notarytool's xar_open_digest_verify on files there; /tmp is
# never backed up. See CLAUDE.md "Time Machine notarize hang".
TMP_WORK=$(mktemp -d /tmp/canopy-dmg.XXXXXX)
# Detach before removing, and in that order. notarytool mounts the DMG it is
# submitting, and that mount is of the copy in HERE, not of anything under
# build/ — so the preflight below cannot see it, and `rm -rf` alone leaves it
# attached: an image outlives the deletion of its backing file. That is how a
# release that dies mid-notarize hangs the NEXT one, with nothing connecting
# the two runs (hit during 2.14.4; CLAUDE.md "notarytool DMG-mount hang").
# Failure is logged, not fatal — the trap runs on the success path too, and a
# release that already produced its DMG must not be failed by cleanup.
trap '"${ROOT_DIR}/scripts/detach_dmg_mounts.sh" "$TMP_WORK" >/dev/null 2>&1 || \
      echo "warning: could not detach images under $TMP_WORK; run scripts/detach_dmg_mounts.sh before the next release" >&2
      rm -rf "$TMP_WORK"' EXIT INT TERM
TMP_DMG="${TMP_WORK}/${DMG_NAME}.dmg"

DEVELOPER_ID="Developer ID Application: Tomohiko Koyama (VCFY2GFR89)"
KEYCHAIN_PROFILE="notarytool-profile"

# A stale DMG mount has preceded every `notarytool submit` hang we have hit, so
# clear ours before the ~10 min build rather than after it. See CLAUDE.md
# "notarytool DMG-mount hang" and issue #127. Lives here rather than in
# release.sh so a standalone package_dmg.sh run is covered too.
echo "=== Checking for leftover DMG mounts ==="
if ! "${ROOT_DIR}/scripts/detach_dmg_mounts.sh" "${BUILD_DIR}" "$TMP_WORK"; then
  echo "Error: could not confirm that nothing under ${BUILD_DIR} is attached." >&2
  echo "Not proceeding — see the error above; 'hdiutil info' lists what is attached." >&2
  exit 1
fi

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
hdiutil create \
  -volname "${VOL_NAME}" \
  -srcfolder "${DMG_ROOT}" \
  -ov \
  -format UDZO \
  "${TMP_DMG}"

echo "=== Notarizing DMG ==="
codesign --force --sign "$DEVELOPER_ID" "${TMP_DMG}"

xcrun notarytool submit "${TMP_DMG}" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

xcrun stapler staple "${TMP_DMG}"

rm -f "${OUT_DMG}"
cp "${TMP_DMG}" "${OUT_DMG}"

echo "=== Done ==="
echo "Created notarized DMG:"
echo "${OUT_DMG}"
