#!/usr/bin/env bash
set -euo pipefail

# Wait until the public appcast offers <version>, so a release is not called
# done while Sparkle still serves the previous one.
# Usage: ./scripts/wait_for_appcast.sh <version>
#
# Two failures have been seen after update_appcast.sh pushed to gh-pages:
# no Pages build started at all, and a build that started on the right commit
# and failed with an empty conclusion while pages/builds/latest kept saying
# "building". Both were fixed by requesting a build again, so this does that
# once and then fails loudly rather than retrying forever.

VERSION="${1:?usage: wait_for_appcast.sh <version>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FEED_URL=$(sed -n 's/.*SUFeedURL: *"\(.*\)".*/\1/p' "${ROOT_DIR}/project.yml")
[[ -n "$FEED_URL" ]] || { echo "error: SUFeedURL not found in project.yml" >&2; exit 1; }
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
SHA=$(git -C "$ROOT_DIR" ls-remote origin refs/heads/gh-pages | cut -f1)
[[ -n "$SHA" ]] || { echo "error: no gh-pages branch on origin" >&2; exit 1; }
echo "Waiting for appcast ${VERSION} (gh-pages ${SHA:0:7}, ${FEED_URL})"

# Newest pages-build-deployment run on $SHA with an id above $1 (default 0). Empty when none.
find_run() {
  gh run list --repo "$REPO" --workflow pages-build-deployment --limit 10 \
    --json databaseId,headSha \
    --jq "[.[] | select(.headSha == \"${SHA}\" and .databaseId > ${1:-0})][0].databaseId // empty"
}

# Wait up to 3 minutes for a run newer than $1 to appear on $SHA.
await_run() {
  local id=""
  for _ in $(seq 1 36); do
    id=$(find_run "${1:-0}")
    [[ -n "$id" ]] && { echo "$id"; return 0; }
    sleep 5
  done
  return 1
}

request_build() {
  echo "Requesting a Pages build"
  gh api -X POST "repos/${REPO}/pages/builds" --jq .status >/dev/null
}

RUN_ID=""
if ! RUN_ID=$(await_run); then
  echo "No Pages build started for ${SHA:0:7}"
  request_build
  RUN_ID=$(await_run) || { echo "error: no Pages build started after requesting one" >&2; exit 1; }
fi

echo "Watching Pages run ${RUN_ID}"
if ! gh run watch "$RUN_ID" --repo "$REPO" --exit-status >/dev/null; then
  echo "Pages run ${RUN_ID} failed"
  request_build
  FIRST="$RUN_ID"
  RUN_ID=$(await_run "$FIRST") || { echo "error: no new Pages build started after requesting one" >&2; exit 1; }
  echo "Watching Pages run ${RUN_ID}"
  if ! gh run watch "$RUN_ID" --repo "$REPO" --exit-status >/dev/null; then
    echo "error: Pages run ${RUN_ID} failed again: https://github.com/${REPO}/actions/runs/${RUN_ID}" >&2
    exit 1
  fi
fi

# The CDN caches for up to max-age=600, so allow a little more than that.
for i in $(seq 1 66); do
  latest=$(curl -fsS "${FEED_URL}?t=$(date +%s)" 2>/dev/null \
    | sed -n 's:.*<title>\([0-9][^<]*\)</title>.*:\1:p' | head -1) || latest=""
  if [[ "$latest" == "$VERSION" ]]; then
    echo "Appcast live: ${VERSION} (after $((i * 10))s of polling)"
    exit 0
  fi
  sleep 10
done
echo "error: ${FEED_URL} still offers '${latest:-nothing}' after 11 minutes" >&2
exit 1
