#!/usr/bin/env bash
set -euo pipefail

# Detach every attached disk image whose backing file lives under one of the
# given directories. The filter matches the image's BACKING FILE, not its
# mountpoint — which is why it reaches a DMG that strip_sh_xattrs mounted at a
# mktemp path under /var/folders, as long as the .dmg itself is under a scope.
#
# A DELETED backing file still matches: the comparison is lexical (Python's
# realpath does not require existence), and hdiutil keeps listing the path of a
# mount whose file is gone. Measured 2026-08-13 — worth knowing, because the
# release hang that motivated the multi-directory support looked like a
# deleted-file problem and was purely a scope problem.
#
# Why this exists: CLAUDE.md "notarytool DMG-mount hang". A stale mount makes
# the NEXT release hang in `xcrun notarytool submit`, with nothing connecting
# the two runs.
#
# Scope is a directory prefix: nothing outside the given directories is ever
# touched. Inside them, everything attached is detached unconditionally —
# including a DMG the developer double-clicked to inspect. That is the intended
# trade for a release script, not an oversight. Pass the narrowest directories
# that cover the producers; a release run needs both build/ and the mktemp
# workdir the DMG is submitted from.
#
# **Do not run this while a notarize is in flight.** Detaching notarytool's own
# in-progress mount corrupts its submission (CLAUDE.md has the error it dies
# with). This is a preflight and a cleanup, never a concurrent sweep.
#
# Usage: detach_dmg_mounts.sh <directory> [<directory>...]  (relative paths
#        resolve against cwd; a directory that does not exist is still a valid
#        scope, since its images may outlive it)
# Exit:  0 = every image found in scope detached. Deliberately NOT "nothing is
#            attached": the table is never re-read afterwards.
#        1 = a detach failed even after killing the image's helper, OR the
#            attach table could not be read — either way, do not notarize
#        2 = usage error

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <directory> [<directory>...]" >&2
  exit 2
fi

# Prefixes are passed as argv. NOT as `VAR=x hdiutil ... | python3`: an
# assignment prefix scopes to the single command it precedes, so python3 on the
# other side of the pipe inherits nothing and the filter silently matches
# nothing (issue #127). argv also keeps the paths out of the `-c` source string,
# which is what the env form was reached for in the first place — paths with
# spaces or apostrophes stay safe either way.
#
# Emits one TAB-separated row per image: <dev-entry> <hdid-pid> <image-path>.
# `hdid-pid` is hdiutil's own binding from the image to the diskimages-helper
# holding it, which is what makes the escalation below safe — the alternative,
# matching a helper by elapsed time, is a guess.
list_images() {
  # hdiutil's stderr is deliberately NOT discarded: it is silent on success
  # (measured: 0 bytes), so anything it says here is the reason enumeration
  # failed — which is the one line the caller needs and cannot reconstruct.
  # shellcheck disable=SC2016
  hdiutil info -plist | python3 -c '
import os, plistlib, sys

prefixes = [os.path.realpath(p).rstrip("/") + "/" for p in sys.argv[1:]]
try:
    data = plistlib.loads(sys.stdin.buffer.read())
except Exception as exc:
    print("hdiutil info -plist unparseable: %s" % exc, file=sys.stderr)
    sys.exit(1)

for img in data.get("images", []):
    path = img.get("image-path") or ""
    if not path:
        continue
    real = os.path.realpath(path)
    if not any(real.startswith(p) for p in prefixes):
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
        print("%s\t%s\t%s" % (devs[0], img.get("hdid-pid") or "", path))
' "$@"
}

# Kill the diskimages-helper bound to one image, but only after confirming the
# pid still IS that helper — a pid is reusable, and this runs unattended in a
# release script. Returns non-zero without killing anything if it cannot.
kill_helper() {
  local pid="$1"
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  local cmd
  cmd=$(ps -p "$pid" -o comm= 2>/dev/null) || return 1
  [[ "$cmd" == *diskimages-helper ]] || return 1
  kill "$pid" 2>/dev/null || return 1
  # The helper exits promptly once signalled; give it a moment before retrying
  # the detach, or the retry races it and reports busy again.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ps -p "$pid" >/dev/null 2>&1 || return 0
    sleep 0.2
  done
  kill -9 "$pid" 2>/dev/null || true
  sleep 0.2
  return 0
}

# True when hdiutil still lists the device. Used only after killing a helper,
# where the device may already be gone. Treats an unreadable table as "still
# attached" so the caller escalates rather than assuming success.
still_attached() {
  local dev="$1" table
  table=$(hdiutil info 2>/dev/null) || return 0
  grep -qF "$dev" <<<"$table"
}

if ! IMAGES=$(list_images "$@"); then
  echo "error: could not enumerate attached disk images in scope" >&2
  exit 1
fi

detached=0
failed=0
killed=0
while IFS=$'\t' read -r dev pid path; do
  [[ -z "$dev" ]] && continue
  if hdiutil detach "$dev" -quiet 2>/dev/null || hdiutil detach "$dev" -force -quiet 2>/dev/null; then
    detached=$((detached + 1))
    continue
  fi
  # Both ordinary attempts lost. The remaining cause seen in the wild is an
  # orphaned diskimages-helper whose parent (notarytool) died mid-submit: it
  # holds the device, `lsof` names nobody, and -force still answers
  # "Resource busy". Kill the helper hdiutil itself points at, then retry —
  # this last attempt drops -quiet, because -quiet suppresses detach's stderr
  # outright (measured: 0 bytes with it, 51 with a real reason without it) and
  # a reason the operator can read is worth more than a tidy line here.
  if kill_helper "$pid"; then
    killed=$((killed + 1))
    # Killing the helper usually takes the attachment with it, and then the
    # retry below fails with "detach failed - No such file or directory" on a
    # device that is already gone. Measured 2026-08-13 against a SIGSTOPped
    # helper: without this check the script reports failed=1 and exit 1 for a
    # state that is clean, which aborts a release for nothing. Ask the table,
    # not the error message.
    if ! still_attached "$dev"; then
      detached=$((detached + 1))
      continue
    fi
    if hdiutil detach "$dev" -force; then
      detached=$((detached + 1))
      continue
    fi
  fi
  failed=$((failed + 1))
  echo "  error: failed to detach $dev (image ${path})" >&2
done <<<"$IMAGES"

if (( detached > 0 || failed > 0 )); then
  echo "Disk image cleanup: detached=${detached} failed=${failed} helpers-killed=${killed}" >&2
fi

(( failed == 0 ))
