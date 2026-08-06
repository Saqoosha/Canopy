#!/usr/bin/env bash
set -euo pipefail

# Detach every attached disk image whose backing file lives under <directory>.
# The filter matches the image's BACKING FILE, not its mountpoint — which is why
# it reaches a DMG that strip_sh_xattrs mounted at a mktemp path under
# /var/folders, as long as the .dmg itself is under <directory>.
#
# Why this exists, and what it does not cover: CLAUDE.md "notarytool DMG-mount
# hang". The short version is that a stale mount makes the NEXT release hang in
# `xcrun notarytool submit`, and that a directory scope reaches the producers
# that work inside build/ but not notarytool's own in-flight mount.
#
# Scope is a directory prefix: nothing outside <directory> is ever touched.
# Inside it, everything attached is detached unconditionally — including a DMG
# the developer double-clicked to inspect. That is the intended trade for a
# release script, not an oversight.
#
# Usage: detach_dmg_mounts.sh <directory>   (a relative path resolves against cwd)
# Exit:  0 = every image found under <directory> detached. Deliberately NOT
#            "nothing is attached": the table is never re-read afterwards.
#        1 = a detach command failed, OR the attach table could not be read —
#            either way the caller must not notarize
#        2 = usage error

PREFIX="${1:-}"
if [[ -z "$PREFIX" ]]; then
  echo "Usage: $0 <directory>" >&2
  exit 2
fi

# The prefix is passed as argv. NOT as `VAR=x hdiutil ... | python3`: an
# assignment prefix scopes to the single command it precedes, so python3 on the
# other side of the pipe inherits nothing and the filter silently matches
# nothing (issue #127). argv also keeps the path out of the `-c` source string,
# which is what the env form was reached for in the first place — paths with
# spaces or apostrophes stay safe either way.
#
# Both sides go through realpath so a symlinked build/ still matches; the old
# filter compared raw strings and would have missed it.
list_devs() {
  # hdiutil's stderr is deliberately NOT discarded: it is silent on success
  # (measured: 0 bytes), so anything it says here is the reason enumeration
  # failed — which is the one line the caller needs and cannot reconstruct.
  # SC2016 fires on the backticks in the Python comments below, which shellcheck
  # reads as command substitution. Single-quoting is deliberate — nothing is
  # expanded into this source, $PREFIX arrives as argv — so the warning is
  # noise here. Reword those comments without backticks and this goes dead.
  # shellcheck disable=SC2016
  hdiutil info -plist | python3 -c '
import os, plistlib, sys

prefix = os.path.realpath(sys.argv[1]).rstrip("/") + "/"
try:
    data = plistlib.loads(sys.stdin.buffer.read())
except Exception as exc:
    print("hdiutil info -plist unparseable: %s" % exc, file=sys.stderr)
    sys.exit(1)

for img in data.get("images", []):
    path = img.get("image-path") or ""
    if not path or not os.path.realpath(path).startswith(prefix):
        continue
    # system-entities lists the whole device tree, and we detach one entry from
    # it. `hdiutil create -format UDZO` with no -fs yields APFS-in-GPT, so every
    # DMG here spans TWO parent devices that tie on length — measured on a real
    # Canopy DMG: disk24 (GPT scheme) + disk25 (APFS container) at 11 chars
    # each, plus their s1 slices at 13. So it is the tie-break, not the length,
    # that makes this correct: `sorted` is stable and hdiutil lists the GPT
    # device first, and detaching that one cascades to the other three
    # (measured). Length only rules out the slices — and even that assumes one
    # digit width, since disk9 sorts before disk10.
    devs = sorted(
        (e.get("dev-entry", "") for e in img.get("system-entities", []) if e.get("dev-entry")),
        key=len,
    )
    if devs:
        print(devs[0])
' "$PREFIX"
}

if ! DEVS=$(list_devs); then
  echo "error: could not enumerate attached disk images under ${PREFIX}" >&2
  exit 1
fi

detached=0
failed=0
while IFS= read -r dev; do
  [[ -z "$dev" ]] && continue
  # No reason from hdiutil reaches the operator here, and dropping the
  # redirection does not change that: `-quiet` suppresses detach's stderr
  # outright (measured — 0 bytes with it, 51 with a real reason without it), so
  # both redirections are inert. Surfacing the reason means dropping `-quiet`
  # from the last attempt, which is a behaviour change, not a comment fix.
  if hdiutil detach "$dev" -quiet 2>/dev/null || hdiutil detach "$dev" -force -quiet 2>/dev/null; then
    detached=$((detached + 1))
  else
    failed=$((failed + 1))
    echo "  error: failed to detach $dev (image under ${PREFIX})" >&2
  fi
done <<<"$DEVS"

if (( detached > 0 || failed > 0 )); then
  echo "Disk image cleanup under ${PREFIX}: detached=${detached} failed=${failed}" >&2
fi

(( failed == 0 ))
