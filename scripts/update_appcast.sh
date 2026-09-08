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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
SPARKLE_BIN="${BUILD_DIR}/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST_DIR="${BUILD_DIR}/appcast"

# Sparkle's generate_appcast attaches every DMG it inspects for delta
# generation and does not detach them — they pile up across releases as
# stealth mounts (no /Volumes/ entry), holding file descriptors on the
# source DMGs and crowding the /dev/disk* table. strip_sh_xattrs below attaches
# them too, and can leave one behind when both of its detach attempts fail.
# Eject anything still attached from a DMG under $APPCAST_DIR on exit so each
# run leaves a clean state, including the paths where the script aborts mid-run
# (issue #127). Scope is $APPCAST_DIR — nothing outside it is touched, which
# also means the `stripped-*` intermediates strip_sh_xattrs creates directly in
# $BUILD_DIR are not covered here; package_dmg.sh's wider scan is what would
# catch one of those.
cleanup_appcast_mounts() {
  # `|| true` so this cannot abort the rest of the trap it runs in. It does mean
  # a mount we could not eject leaves the run green with only the helper's
  # stderr to show for it — the next release's package_dmg.sh pre-notarize check
  # is what actually stops anything.
  "${SCRIPT_DIR}/detach_dmg_mounts.sh" "$APPCAST_DIR" || true
}
trap cleanup_appcast_mounts EXIT

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

# `hdiutil detach` fails transiently while something still holds the volume
# (Spotlight indexing it, or the find that just walked it). Unguarded under
# `set -e` that aborts the whole script with the image still attached, which is
# what hangs the next release's notarization (issue #127). Try force as a second
# chance, then hand the mount to the EXIT trap rather than dying here.
detach_mount() {
  local mount="$1"
  hdiutil detach "$mount" -quiet 2>/dev/null && return 0
  hdiutil detach "$mount" -force -quiet 2>/dev/null && return 0
  echo "  warn: could not detach $mount — the EXIT trap retries, but if that" >&2
  echo "        also fails this run still exits 0; check 'hdiutil info'" >&2
  return 1
}

# Strip code-signed xattrs from shell scripts in local DMG copies before delta generation.
# codesign adds com.apple.cs.* xattrs to resource files; Sparkle can't diff files with
# these xattrs. File contents (hashed in CodeResources) are unaffected, so this is safe.
#
# REBUILDING A DMG CHANGES ITS BYTES, and generate_appcast signs whatever is in
# $APPCAST_DIR while release.sh publishes build/Canopy-X.dmg — so a rebuild here
# makes the appcast's EdDSA signature and length describe a file nobody can
# download. Sparkle then fails the check and SILENTLY drops that item, offering
# the previous version as "latest" (issue #188). Two guards follow from that:
# the predicate below matches ONLY the xattrs this function exists to remove,
# and the current version's DMG is never passed here at all.
#
# The predicate is deliberately `com.apple.cs.` and not "has any xattr". The
# published 2.28.0 DMG carries exactly one .sh xattr — com.apple.provenance,
# which the kernel applies and `xattr -c` does not remove — so "any xattr"
# matched on every release since at least 2.26.1 and rebuilt every DMG every
# run, which is why the mismatch was structural rather than a one-off.
sh_has_cs_xattrs() {
  find "$1" -name "*.sh" -exec xattr {} \; 2>/dev/null | grep -q '^com\.apple\.cs\.'
}

strip_sh_xattrs() {
  local DMG="$1"
  local MOUNT TMP_CONTENT REBUILD=0
  MOUNT=$(mktemp -d)
  TMP_CONTENT=$(mktemp -d)
  if ! hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet -readonly 2>/dev/null; then
    rm -rf "$MOUNT" "$TMP_CONTENT"
    return 0
  fi
  if sh_has_cs_xattrs "$MOUNT"; then
    REBUILD=1
    cp -Rp "$MOUNT"/* "$TMP_CONTENT/" 2>/dev/null || true
  fi
  # Detach as soon as the read is done (the pre-existing code did this too —
  # what changed is that both branches now share one call site and a failure no
  # longer kills the script). When the detach DOES fail we still fall through to
  # the rebuild below, so the mv can replace the backing file of a live mount;
  # that is survivable because the mount holds the old inode and the EXIT trap
  # matches on the recorded image-path, not on the file. Only remove the
  # mountpoint directory when the detach succeeded — rm -rf on a live mount is
  # not a cleanup, so the directory is deliberately leaked instead.
  if detach_mount "$MOUNT"; then
    rm -rf "$MOUNT"
  fi
  if (( REBUILD )); then
    find "$TMP_CONTENT" -name "*.sh" -exec xattr -c {} \;
    local TEMP_DMG; TEMP_DMG=$(mktemp "${BUILD_DIR}/stripped-XXXXXX")
    rm -f "$TEMP_DMG"  # mktemp creates the file; hdiutil create needs it absent
    hdiutil create -srcfolder "$TMP_CONTENT" -format UDZO -volname "Canopy" -o "$TEMP_DMG" -quiet
    mv "${TEMP_DMG}.dmg" "$DMG"
    echo "  Stripped xattrs: $(basename "$DMG")"
  fi
  rm -rf "$TMP_CONTENT"
}

# The current version's DMG is the one release.sh already published, so it must
# reach generate_appcast byte-for-byte. It is skipped rather than checked-and-
# skipped-if-clean: a conditional here would put the appcast's correctness back
# on a predicate, which is the shape that broke. package_dmg.sh already runs
# `xattr -c` over the .sh files before creating it, so a cs xattr surviving into
# it is a regression there — reported as a warning, because it only degrades
# delta generation while rebuilding would break the update itself.
echo "Stripping shell script xattrs from local DMG copies..."
for _DMG in "$APPCAST_DIR"/*.dmg; do
  if [[ "$(basename "$_DMG")" == "$DMG_NAME" ]]; then
    echo "  Skipping $DMG_NAME (published artifact — must stay byte-identical)"
    continue
  fi
  strip_sh_xattrs "$_DMG"
done

_CUR_MOUNT=$(mktemp -d)
if hdiutil attach "${APPCAST_DIR}/${DMG_NAME}" -mountpoint "$_CUR_MOUNT" -nobrowse -quiet -readonly 2>/dev/null; then
  if sh_has_cs_xattrs "$_CUR_MOUNT"; then
    echo "  warn: ${DMG_NAME} still carries com.apple.cs.* xattrs on a .sh file." >&2
    echo "        package_dmg.sh's strip regressed; deltas from this release will" >&2
    echo "        be degraded, but the update itself is unaffected." >&2
  fi
  detach_mount "$_CUR_MOUNT" && rm -rf "$_CUR_MOUNT"
else
  rm -rf "$_CUR_MOUNT"
fi

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

# The failure this guards against is silent by construction: Sparkle downloads
# the published DMG, checks it against the appcast's EdDSA signature, and on a
# mismatch DISCARDS the item without a log line or an error, then offers the
# next-oldest item as "latest". Nothing on the release side looks wrong — the
# appcast parses, GitHub has the asset, the tag exists (issue #188). So assert
# the one property that actually has to hold, against the file users will
# really download, before any of it reaches gh-pages.
echo "=== Verifying appcast matches the published DMG ==="
PUBLISHED_SIZE=$(gh release view "v${VERSION}" --json assets \
  --jq ".assets[] | select(.name == \"${DMG_NAME}\") | .size" 2>/dev/null || echo "")
if [[ -z "$PUBLISHED_SIZE" ]]; then
  echo "Error: ${DMG_NAME} is not attached to release v${VERSION}." >&2
  echo "Not pushing an appcast that points at a file nobody can download." >&2
  exit 1
fi

# Length alone is a proxy, and this guard exists precisely because a proxy
# already failed once. Two same-size DMGs sign differently, and the local copy
# can diverge from the published one without changing size — a re-run against a
# stale or replaced build/Canopy-X.dmg, say. So fetch the bytes users will
# actually download and compare them against the exact file generate_appcast
# signed. One ~3.5 MB download at the end of a release that has already built,
# notarized and uploaded is not a cost worth optimising away.
VERIFY_DIR=$(mktemp -d)
if ! gh release download "v${VERSION}" --pattern "${DMG_NAME}" --dir "$VERIFY_DIR" --clobber >/dev/null 2>&1; then
  rm -rf "$VERIFY_DIR"
  echo "Error: could not download ${DMG_NAME} from release v${VERSION} to verify it." >&2
  exit 1
fi
if ! cmp -s "${VERIFY_DIR}/${DMG_NAME}" "${APPCAST_DIR}/${DMG_NAME}"; then
  echo "Error: the DMG the appcast signed is not the DMG that was published." >&2
  echo "  signed:    ${APPCAST_DIR}/${DMG_NAME} ($(stat -f%z "${APPCAST_DIR}/${DMG_NAME}") bytes)" >&2
  echo "  published: ${DMG_NAME} on v${VERSION} (${PUBLISHED_SIZE} bytes)" >&2
  echo "Sparkle would fail the signature check and silently skip this update." >&2
  echo "Nothing was pushed to gh-pages." >&2
  rm -rf "$VERIFY_DIR"
  exit 1
fi
rm -rf "$VERIFY_DIR"
echo "  ${DMG_NAME}: byte-identical to the published asset"

# Not subsumed by the byte comparison above: that one proves the right file was
# available to be signed, this one proves the appcast's item actually describes
# it. The feed is generated on top of the one fetched from gh-pages, so a
# generate_appcast that preserves a stale entry for this version instead of
# re-signing leaves a correct DMG beside a wrong enclosure.
APPCAST_SIZE=$(python3 - "${APPCAST_DIR}/appcast.xml" "$DMG_NAME" <<'PYEOF'
import re, sys
xml = open(sys.argv[1]).read()
name = sys.argv[2]
for tag in re.findall(r'<enclosure\b[^>]*>', xml):
    url = re.search(r'url="([^"]*)"', tag)
    if url and url.group(1).endswith('/' + name):
        length = re.search(r'length="(\d+)"', tag)
        print(length.group(1) if length else '')
        break
PYEOF
)

if [[ "$APPCAST_SIZE" != "$PUBLISHED_SIZE" ]]; then
  echo "Error: appcast describes a different file than the one published." >&2
  echo "  appcast length:   ${APPCAST_SIZE:-<no enclosure for ${DMG_NAME}>}" >&2
  echo "  published asset:  ${PUBLISHED_SIZE}" >&2
  echo "Sparkle would fail the signature check and silently skip this update." >&2
  echo "Nothing was pushed to gh-pages." >&2
  exit 1
fi
echo "  ${DMG_NAME}: ${APPCAST_SIZE} bytes, matches the published asset"

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
# Mount cleanup goes FIRST. Under `set -e` a failing command in a trap body
# aborts the rest of the trap (measured: `trap 'false; f' EXIT` never reaches f
# and exits 1), so an `rm -rf` that hits a permission error or a live mountpoint
# would silently skip the cleanup this whole script depends on. A leaked mktemp
# dir costs nothing; a leaked mount costs the next release. The trade is that a
# detach which HANGS rather than fails now blocks the rm too.
trap 'cleanup_appcast_mounts; rm -rf "$WORKTREE_DIR"' EXIT

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
