#!/usr/bin/env bash
set -euo pipefail

# Update Sparkle appcast.xml and push to gh-pages branch.
# Usage: ./scripts/update_appcast.sh <version>
# Can also be run standalone after a release to regenerate the appcast.
#
# Release notes: fetched from the GitHub Release body and embedded in the
# appcast as Markdown. The Sparkle update dialog displays these notes.
#
# This script also generates delta updates from previous versions and
# uploads them to the GitHub Release for faster incremental updates.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
SPARKLE_BIN="${BUILD_DIR}/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST_DIR="${BUILD_DIR}/appcast"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION=$(grep 'MARKETING_VERSION:' "${ROOT_DIR}/project.yml" | sed 's/.*: *"\(.*\)".*/\1/')
  echo "No version specified, using current: ${VERSION}"
fi

DMG_NAME="Canopy-${VERSION}.dmg"

if [[ ! -x "${SPARKLE_BIN}/generate_appcast" ]]; then
  echo "Error: generate_appcast not found. Build the project first to resolve SPM dependencies."
  exit 1
fi

# Prepare appcast directory with the DMG
mkdir -p "$APPCAST_DIR"

# Clean old delta files to avoid stale artifacts
rm -f "$APPCAST_DIR"/*.delta

# Download DMG from GitHub Release if not available locally
DMG_PATH="${BUILD_DIR}/${DMG_NAME}"
if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found locally, downloading from GitHub Release..."
  gh release download "v${VERSION}" --pattern "${DMG_NAME}" --dir "$BUILD_DIR"
fi
cp "$DMG_PATH" "$APPCAST_DIR/"

# Fetch release notes from GitHub and write as Markdown alongside the DMG
# generate_appcast picks up .md files with matching filename as release notes
NOTES_PATH="${APPCAST_DIR}/Canopy-${VERSION}.md"
echo "Fetching release notes from GitHub Release v${VERSION}..."
RELEASE_BODY=$(gh release view "v${VERSION}" --json body --jq '.body' 2>/dev/null || echo "")
if [[ -n "$RELEASE_BODY" ]]; then
  echo "$RELEASE_BODY" > "$NOTES_PATH"
  echo "  Wrote release notes to $(basename "$NOTES_PATH")"
else
  echo "  No release notes found"
fi

# Download previous version DMGs for delta generation (last 2 only)
echo "Downloading previous DMGs for delta generation..."
RELEASES=$(gh release list --limit 3 --json tagName --jq '.[].tagName')
for TAG in $RELEASES; do
  [[ "$TAG" == "v${VERSION}" ]] && continue
  PREV_VERSION="${TAG#v}"
  PREV_DMG_NAME="Canopy-${PREV_VERSION}.dmg"
  if [[ ! -f "${APPCAST_DIR}/${PREV_DMG_NAME}" ]]; then
    echo "  Downloading ${PREV_DMG_NAME} from ${TAG}..."
    gh release download "$TAG" --pattern "${PREV_DMG_NAME}" --dir "$APPCAST_DIR" 2>/dev/null || \
      echo "  Skipping ${TAG} (no DMG found)"
  fi
  # Also fetch release notes for previous versions (for regeneration)
  PREV_NOTES_PATH="${APPCAST_DIR}/Canopy-${PREV_VERSION}.md"
  if [[ ! -f "$PREV_NOTES_PATH" ]]; then
    PREV_BODY=$(gh release view "$TAG" --json body --jq '.body' 2>/dev/null || echo "")
    if [[ -n "$PREV_BODY" ]]; then
      echo "$PREV_BODY" > "$PREV_NOTES_PATH"
    fi
  fi
done

# Strip code-signed xattrs from shell scripts in local DMG copies before delta generation.
# codesign adds com.apple.cs.* xattrs to resource files; Sparkle can't diff files with
# these xattrs. File contents (hashed in CodeResources) are unaffected, so this is safe.
strip_sh_xattrs() {
  local DMG="$1"
  local MOUNT TMP_CONTENT
  MOUNT=$(mktemp -d)
  TMP_CONTENT=$(mktemp -d)
  hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet -readonly 2>/dev/null || {
    rm -rf "$MOUNT" "$TMP_CONTENT"; return 0
  }
  # Only rebuild if any .sh has xattrs
  if find "$MOUNT" -name "*.sh" -exec xattr {} \; 2>/dev/null | grep -q .; then
    cp -Rp "$MOUNT"/* "$TMP_CONTENT/" 2>/dev/null || true
    hdiutil detach "$MOUNT" -quiet
    find "$TMP_CONTENT" -name "*.sh" -exec xattr -c {} \;
    local TEMP_DMG; TEMP_DMG=$(mktemp "${BUILD_DIR}/stripped-XXXXXX")
    rm -f "$TEMP_DMG"  # mktemp creates the file; hdiutil create needs it absent
    hdiutil create -srcfolder "$TMP_CONTENT" -format UDZO -volname "Canopy" -o "$TEMP_DMG" -quiet
    mv "${TEMP_DMG}.dmg" "$DMG"
    echo "  Stripped xattrs: $(basename "$DMG")"
  else
    hdiutil detach "$MOUNT" -quiet
  fi
  rm -rf "$MOUNT" "$TMP_CONTENT"
}

echo "Stripping shell script xattrs from local DMG copies..."
for _DMG in "$APPCAST_DIR"/*.dmg; do
  strip_sh_xattrs "$_DMG"
done

# If an existing appcast.xml exists on gh-pages, fetch it so generate_appcast
# can append to it (preserving older versions in the feed).
EXISTING_APPCAST=$(mktemp)
if git show origin/gh-pages:appcast.xml > "$EXISTING_APPCAST" 2>/dev/null; then
  cp "$EXISTING_APPCAST" "$APPCAST_DIR/appcast.xml"
  echo "Fetched existing appcast.xml from gh-pages"
fi
rm -f "$EXISTING_APPCAST"

# Generate/update appcast.xml with Sparkle's tool
# --embed-release-notes: embeds .md release notes into the feed directly
# --link: adds product URL to each update item
"${SPARKLE_BIN}/generate_appcast" \
  --download-url-prefix "https://github.com/Saqoosha/Canopy/releases/download/v${VERSION}/" \
  --link "https://github.com/Saqoosha/Canopy" \
  --embed-release-notes \
  "$APPCAST_DIR"

if [[ ! -f "${APPCAST_DIR}/appcast.xml" ]]; then
  echo "Error: generate_appcast failed to create appcast.xml"
  exit 1
fi

# Normalize channel metadata: generate_appcast always appends <title>AppName</title>,
# so we replace the entire block between <channel> and first <item> with canonical metadata.
python3 - "$APPCAST_DIR/appcast.xml" <<'PYEOF'
import sys, re

appcast_path = sys.argv[1]

with open(appcast_path) as f:
    content = f.read()

channel_meta = (
    '\n        <title>Canopy Changelog</title>\n'
    '        <link>https://github.com/Saqoosha/Canopy</link>\n'
    '        <description>Most recent changes with links to updates.</description>\n'
    '        <language>en</language>\n        '
)

# Replace everything between <channel> and the first <item> with canonical metadata
new_content = re.sub(
    r'(<channel>).*?(<item>)',
    lambda m: m.group(1) + channel_meta + m.group(2),
    content,
    count=1,
    flags=re.DOTALL
)

if new_content != content:
    with open(appcast_path, 'w') as f:
        f.write(new_content)
    print("  Normalized channel metadata")
PYEOF

echo "Generated appcast.xml:"
cat "${APPCAST_DIR}/appcast.xml"

# Upload delta files to the GitHub Release
DELTAS=("$APPCAST_DIR"/*.delta)
if [[ -e "${DELTAS[0]}" ]]; then
  echo "Uploading delta updates to GitHub Release v${VERSION}..."
  for DELTA in "${DELTAS[@]}"; do
    echo "  Uploading $(basename "$DELTA") ($(du -h "$DELTA" | cut -f1))"
    gh release upload "v${VERSION}" "$DELTA" --clobber
  done
else
  echo "No delta files generated"
fi

# Push appcast.xml to gh-pages branch
WORKTREE_DIR=$(mktemp -d)
trap 'rm -rf "$WORKTREE_DIR"' EXIT

# Check if gh-pages branch exists
if git rev-parse --verify origin/gh-pages >/dev/null 2>&1; then
  git worktree add "$WORKTREE_DIR" origin/gh-pages --detach
  cd "$WORKTREE_DIR"
  git checkout -B gh-pages origin/gh-pages
else
  # Create orphan gh-pages branch
  git worktree add --detach "$WORKTREE_DIR"
  cd "$WORKTREE_DIR"
  git checkout --orphan gh-pages
  git rm -rf . 2>/dev/null || true
fi

cp "${APPCAST_DIR}/appcast.xml" "$WORKTREE_DIR/appcast.xml"

git add appcast.xml
if git diff --cached --quiet; then
  echo "appcast.xml unchanged, skipping push"
else
  git commit -m "Update appcast for v${VERSION}"
  git push origin gh-pages
  echo "Pushed appcast.xml to gh-pages"
fi

cd "$ROOT_DIR"
git worktree remove "$WORKTREE_DIR" 2>/dev/null || true
