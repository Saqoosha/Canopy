#!/usr/bin/env bash
set -euo pipefail

# Re-sign every DMG enclosure in the published appcast against the file that is
# actually attached to its GitHub Release, and push the corrections to gh-pages.
#
# Why this exists: for as long as update_appcast.sh rebuilt DMGs before signing
# them (issue #188), every item it wrote described bytes nobody could download.
# generate_appcast does NOT re-sign an item that already exists in the feed it
# was handed, so fixing the cause does not repair the entries already published
# — measured after the 2.28.1 release, where 2.28.1 was correct and 2.28.0,
# 2.27.0, 1.5.0 and 1.4.3 were all still wrong. This is the repair half.
#
# Usage:
#   ./scripts/repair_appcast.sh            # audit only, changes nothing
#   ./scripts/repair_appcast.sh --push     # rewrite and push to gh-pages
#
# Scope is deliberately the <enclosure> whose url ends in .dmg. Delta enclosures
# are left alone: a .delta and its signature were produced by the same
# generate_appcast run, so they agree with each other. A delta computed from a
# rebuilt DMG still fails to apply against the real installed bundle, but
# Sparkle's response to that is to fall back to the full download — degraded,
# not broken — and the only real fix is regenerating them, which the next
# release does on its own now that nothing is rebuilt.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
SPARKLE_BIN="${BUILD_DIR}/SourcePackages/artifacts/sparkle/Sparkle/bin"

PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

if [[ ! -x "${SPARKLE_BIN}/sign_update" ]]; then
  echo "Error: sign_update not found. Build the project first to resolve SPM dependencies." >&2
  exit 1
fi

cd "$ROOT_DIR"

WORK=$(mktemp -d)
WORKTREE_DIR=""

# EXIT cleans up; INT/TERM clean up AND exit. A trap that only cleans on a
# signal returns control to the interrupted line, so a Ctrl+C during the audit
# would fall through into the commit and push below.
cleanup() {
  rm -rf "$WORK"
  [[ -n "$WORKTREE_DIR" ]] && rm -rf "$WORKTREE_DIR"
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

echo "=== Fetching published appcast from gh-pages ==="
git fetch origin gh-pages --quiet
git show origin/gh-pages:appcast.xml > "${WORK}/appcast.xml"

# Every DMG the feed references, in feed order. Read with a while loop rather
# than `mapfile`: that builtin arrived in bash 4 and macOS still ships 3.2 at
# /bin/bash, where it would fail before checking a single entry.
DMGS=()
while IFS= read -r _NAME; do
  [[ -n "$_NAME" ]] && DMGS+=("$_NAME")
done < <(grep -oE 'url="[^"]*/Canopy-[0-9]+\.[0-9]+\.[0-9]+\.dmg"' "${WORK}/appcast.xml" \
  | sed -E 's|.*/([^/"]*)"$|\1|' | awk '!seen[$0]++')

if (( ${#DMGS[@]} == 0 )); then
  echo "Error: no DMG enclosures found in the appcast." >&2
  exit 1
fi

echo "=== Checking ${#DMGS[@]} entries against their published assets ==="
CHANGED=0
UNVERIFIABLE=0

for DMG_NAME in "${DMGS[@]}"; do
  VERSION="${DMG_NAME#Canopy-}"
  VERSION="${VERSION%.dmg}"

  if ! gh release download "v${VERSION}" --pattern "$DMG_NAME" --dir "$WORK" --clobber >/dev/null 2>&1; then
    # Not a failure of this script: the release may have been deleted, or the
    # asset never attached. Say so and leave the entry untouched rather than
    # guessing — a wrong signature written here is the exact bug being repaired.
    echo "  ${VERSION}: no published asset, left unchanged"
    UNVERIFIABLE=$(( UNVERIFIABLE + 1 ))
    continue
  fi

  SIGNED=$("${SPARKLE_BIN}/sign_update" "${WORK}/${DMG_NAME}")
  REAL_SIG=$(sed -E 's/.*edSignature="([^"]*)".*/\1/' <<<"$SIGNED")
  REAL_LEN=$(sed -E 's/.*length="([^"]*)".*/\1/' <<<"$SIGNED")

  RESULT=$(python3 - "${WORK}/appcast.xml" "$DMG_NAME" "$REAL_LEN" "$REAL_SIG" <<'PYEOF'
import re, sys

path, name, real_len, real_sig = sys.argv[1:5]
xml = open(path).read()

def fix(match):
    tag = match.group(0)
    url = re.search(r'url="([^"]*)"', tag)
    if not url or not url.group(1).endswith('/' + name):
        return tag
    old_len = re.search(r'length="(\d+)"', tag)
    old_sig = re.search(r'sparkle:edSignature="([^"]*)"', tag)
    if old_len and old_sig and old_len.group(1) == real_len and old_sig.group(1) == real_sig:
        print("OK")
        return tag
    print("FIXED %s -> %s" % (old_len.group(1) if old_len else "?", real_len))
    tag = re.sub(r'length="\d+"', 'length="%s"' % real_len, tag)
    tag = re.sub(r'sparkle:edSignature="[^"]*"',
                 'sparkle:edSignature="%s"' % real_sig, tag)
    return tag

new = re.sub(r'<enclosure\b[^>]*>', fix, xml)
if new != xml:
    open(path, 'w').write(new)
PYEOF
)

  if [[ "$RESULT" == OK ]]; then
    echo "  ${VERSION}: already matches (${REAL_LEN} bytes)"
  else
    echo "  ${VERSION}: ${RESULT#FIXED }  ← repaired"
    CHANGED=$(( CHANGED + 1 ))
  fi
done

echo
if (( CHANGED == 0 )); then
  echo "Nothing to repair."
  (( UNVERIFIABLE > 0 )) && echo "(${UNVERIFIABLE} entr(y|ies) could not be checked — see above)"
  exit 0
fi

echo "Repaired ${CHANGED} entr$( (( CHANGED == 1 )) && echo y || echo ies )."

if (( ! PUSH )); then
  echo "Audit only — nothing was pushed. Re-run with --push to publish."
  exit 0
fi

echo "=== Pushing to gh-pages ==="
WORKTREE_DIR=$(mktemp -d)

git worktree add "$WORKTREE_DIR" origin/gh-pages --detach --quiet
(
  cd "$WORKTREE_DIR"
  git checkout -B gh-pages origin/gh-pages --quiet
  cp "${WORK}/appcast.xml" appcast.xml
  git add appcast.xml
  if git diff --cached --quiet; then
    echo "appcast.xml unchanged on gh-pages, skipping push"
  else
    git commit --quiet -m "Re-sign appcast entries against the published DMGs

Every item written before issue #188 was fixed described a rebuilt DMG
rather than the file attached to the release, so Sparkle failed the
signature check and silently discarded it."
    git push origin gh-pages
    echo "Pushed appcast.xml to gh-pages"
  fi
)
git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
