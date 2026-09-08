#!/usr/bin/env bash
# Sourced by notarize.sh and package_dmg.sh — not executed directly.
#
# Apple's timestamp authority is a network service, and a Developer ID signature
# contacts it on every codesign invocation. When it is down, codesign fails with
#
#   <path>: The timestamp service is not available.
#
# and the release dies. What makes that expensive is WHERE it dies: measured on
# the 2.28.1 release, the failure landed on package_dmg.sh's DMG signature —
# after the ~10 minute Release build and after the app's own notarization round
# trip had already completed. All of it was thrown away for an outage that was
# over within a minute.
#
# The retry is deliberately NOT unconditional. A missing identity, a malformed
# entitlements file, or an unreadable path are all permanent, and retrying them
# only buries the real error under two sleeps. So the predicate matches the one
# message that names the transient service, and everything else fails on the
# first attempt exactly as before.
#
# Retrying is safe here because codesign --force is idempotent: a partially
# written signature is replaced wholesale on the next attempt, so a retry is not
# resuming anything, it is redoing it.

CODESIGN_MAX_ATTEMPTS="${CODESIGN_MAX_ATTEMPTS:-4}"
CODESIGN_RETRY_BASE_DELAY="${CODESIGN_RETRY_BASE_DELAY:-5}"

codesign_retry() {
  local attempt=1
  local delay="$CODESIGN_RETRY_BASE_DELAY"
  local out rc

  while :; do
    # Output is captured so the transient message can be matched, then relayed
    # verbatim to stderr — codesign's own diagnostics must not be swallowed just
    # because this wrapper wanted to read them.
    out=$(codesign "$@" 2>&1)
    rc=$?
    [[ -n "$out" ]] && printf '%s\n' "$out" >&2

    (( rc == 0 )) && return 0

    if ! grep -qi 'timestamp service' <<<"$out"; then
      return "$rc"
    fi

    if (( attempt >= CODESIGN_MAX_ATTEMPTS )); then
      echo "codesign: timestamp service still unavailable after ${attempt} attempts — giving up" >&2
      return "$rc"
    fi

    echo "codesign: timestamp service unavailable; retrying in ${delay}s (attempt $((attempt + 1))/${CODESIGN_MAX_ATTEMPTS})" >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
  done
}
