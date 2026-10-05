#!/usr/bin/env bash
set -euo pipefail

# Wait until the public appcast offers <version>, so a release is not called
# done while Sparkle still serves the previous one.
# Usage: ./scripts/wait_for_appcast.sh <version>
#
# Two failures have been seen after update_appcast.sh pushed to gh-pages:
# no Pages build started at all, and (3.5.0) a pages-build-deployment run that
# started on the right commit and ended `failure` with its build job reporting
# no conclusion, while pages/builds/latest kept saying "building". Both were
# fixed by requesting a build again, so this does that once and then fails.

VERSION="${1:?usage: wait_for_appcast.sh <version>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FEED_URL=$(sed -n 's/.*SUFeedURL: *"\(.*\)".*/\1/p' "${ROOT_DIR}/project.yml")
[[ -n "$FEED_URL" ]] || { echo "error: SUFeedURL not found in project.yml" >&2; exit 1; }
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
SHA=$(git -C "$ROOT_DIR" ls-remote origin refs/heads/gh-pages | cut -f1)
[[ -n "$SHA" ]] || { echo "error: no gh-pages branch on origin" >&2; exit 1; }
command -v timeout >/dev/null || { echo "error: needs timeout (brew install coreutils)" >&2; exit 1; }
echo "Waiting for appcast ${VERSION} (gh-pages ${SHA:0:7}, ${FEED_URL})"

# Exit 2, not 1: inside $(await_run) a 1 means "no run yet" and leads to a rebuild.
die() { echo "error: $*" >&2; exit 2; }

# Newest pages-build-deployment run on $SHA with an id above $1. Empty when none.
find_run() {
  gh run list --repo "$REPO" --workflow pages-build-deployment --limit 30 \
    --json databaseId,headSha \
    --jq "[.[] | select(.headSha == \"${SHA}\" and .databaseId > ${1})][0].databaseId // empty"
}

# Wait up to 3 minutes for a run newer than $1 to appear on $SHA. A gh failure is fatal,
# never "not started yet", so it cannot lead to a needless rebuild.
await_run() {
  local id
  for _ in $(seq 1 36); do
    id=$(find_run "$1") || die "gh run list failed"
    [[ -n "$id" ]] && { echo "$id"; return 0; }
    sleep 5
  done
  return 1
}

# Watch run $1 for up to 20 minutes, then print its conclusion. The conclusion is re-read
# rather than taken from watch's exit status, which is also non-zero on a gh error.
await_conclusion() {
  local rc=0 state
  timeout 1200 gh run watch "$1" --repo "$REPO" --interval 10 >/dev/null || rc=$?
  [[ $rc -ne 124 ]] || die "Pages run $1 still not complete after 20 minutes: https://github.com/${REPO}/actions/runs/$1"
  state=$(gh run view "$1" --repo "$REPO" --json status,conclusion --jq '"\(.status) \(.conclusion)"') \
    || die "gh run view $1 failed"
  [[ "$state" == completed* ]] || die "gh run watch $1 exited ${rc} with the run still ${state}"
  echo "${state#completed }"
}

request_build() {
  echo "Requesting a Pages build"
  gh api -X POST "repos/${REPO}/pages/builds" --jq .status >/dev/null || die "could not request a Pages build"
}

RUN_ID=$(await_run 0) && rc=0 || rc=$?
[[ $rc -le 1 ]] || exit "$rc"
if [[ $rc -eq 1 ]]; then
  echo "No Pages build started for ${SHA:0:7}"
  request_build
  RUN_ID=$(await_run 0) || die "no Pages build started after requesting one"
fi

echo "Watching Pages run ${RUN_ID}"
CONCLUSION=$(await_conclusion "$RUN_ID")
if [[ "$CONCLUSION" != "success" ]]; then
  echo "Pages run ${RUN_ID} ended ${CONCLUSION}: https://github.com/${REPO}/actions/runs/${RUN_ID}"
  request_build
  FIRST="$RUN_ID"
  RUN_ID=$(await_run "$FIRST") || die "no new Pages build started after requesting one"
  echo "Watching Pages run ${RUN_ID}"
  CONCLUSION=$(await_conclusion "$RUN_ID")
  [[ "$CONCLUSION" == "success" ]] \
    || die "Pages run ${RUN_ID} ended ${CONCLUSION} again: https://github.com/${REPO}/actions/runs/${RUN_ID}"
fi

# Polls through the CDN like Sparkle does (a query string does not bypass it), so allow
# a little more than its max-age=600. Proves only the edge nearest this Mac.
START=$(date +%s)
seen="nothing fetched yet"
for _ in $(seq 1 66); do
  if body=$(curl -fsS "$FEED_URL" 2>&1); then
    latest=$(sed -n 's:.*<title>\([0-9][^<]*\)</title>.*:\1:p;' <<<"$body" | sed -n 1p)
    if [[ "$latest" == "$VERSION" ]]; then
      echo "Appcast live: ${VERSION} ($(( $(date +%s) - START ))s after the Pages run)"
      exit 0
    fi
    seen="latest item '${latest:-none found}'"
  else
    seen="fetch failed: ${body}"
  fi
  sleep 10
done
die "${FEED_URL} not offering ${VERSION} after 11 minutes (${seen})"
