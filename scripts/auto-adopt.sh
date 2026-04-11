#!/usr/bin/env bash
# Auto-adopt Claude Code features into Canopy
# Runs daily via launchd, checks for new Claude Code versions,
# analyzes changelog, implements changes, and creates PRs.
set -euo pipefail

# --- PATH setup for launchd environment ---
# mise shims MUST come first so the npm/node that mise manages is preferred
# over any Homebrew-installed versions. Without this, launchd can't find `npm`.
export PATH="$HOME/.local/share/mise/shims:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$HOME/.local/share/canopy-auto-adopt"
VERSION_FILE="$STATE_DIR/last-version.txt"
LOG_FILE="$STATE_DIR/auto-adopt.log"
WORKTREE_DIR="/tmp/canopy-auto-adopt"
MAX_RETRIES=3

SLACK_WEBHOOK_FILE="$STATE_DIR/slack-webhook-url.txt"
CHANGELOG_URL="https://github.com/anthropics/claude-code/releases"

mkdir -p "$STATE_DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG_FILE"; }

# --- Slack notification ---
# Reads webhook URL from file. Silently skips if file doesn't exist.
notify_slack() {
  local color="$1"  # good / warning / danger
  local title="$2"
  local body="$3"

  local webhook_url
  webhook_url=$(cat "$SLACK_WEBHOOK_FILE" 2>/dev/null) || return 0
  [ -n "$webhook_url" ] || return 0

  local escaped_title escaped_body
  escaped_title=$(printf '%s' "$title" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])') || { log "WARNING: python3 not available for Slack notification"; return 0; }
  escaped_body=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])') || return 0

  local payload
  payload=$(cat <<ENDJSON
{
  "username": "Canopy",
  "icon_url": "https://raw.githubusercontent.com/Saqoosha/Canopy/main/images/appicon.png",
  "attachments": [{
    "color": "${color}",
    "blocks": [
      {"type": "header", "text": {"type": "plain_text", "text": "${escaped_title}"}},
      {"type": "section", "text": {"type": "mrkdwn", "text": "${escaped_body}"}}
    ]
  }]
}
ENDJSON
)

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$webhook_url" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>>"$LOG_FILE") || {
    log "WARNING: Slack notification failed (curl error)"
    return 0
  }
  if [ "$http_code" != "200" ]; then
    log "WARNING: Slack notification returned HTTP $http_code"
    return 0
  fi
  _SLACK_NOTIFIED=1
}

# --- Lockfile to prevent concurrent execution ---
LOCKFILE="$STATE_DIR/auto-adopt.lock"
if ! mkdir "$LOCKFILE" 2>/dev/null; then
  if [ -d "$LOCKFILE" ] && find "$LOCKFILE" -maxdepth 0 -mmin +120 | grep -q .; then
    log "WARNING: Removing stale lock (>2h old)"
    rm -rf "$LOCKFILE"
    mkdir "$LOCKFILE"
  else
    log "ERROR: Another instance is running (lockfile exists: $LOCKFILE)"
    exit 1
  fi
fi

# --- Verify required commands ---
for cmd in npm git gh xcodegen xcodebuild claude python3 curl; do
  if ! command -v "$cmd" &>/dev/null; then
    log "ERROR: Required command '$cmd' not found in PATH=$PATH"
    exit 1
  fi
done

# --- Temp file tracking for cleanup ---
PROMPT_FILE=""
BUILD_LOG=""
ISSUE_BODY_FILE=""
PR_BODY_FILE=""
_SLACK_NOTIFIED=0

cleanup_worktree() {
  if [ -d "$WORKTREE_DIR" ]; then
    (cd "$REPO_DIR" && git worktree remove --force "$WORKTREE_DIR" 2>>"$LOG_FILE") \
      || log "WARNING: git worktree remove failed (may already be cleaned up)"
  fi
  rm -rf "$WORKTREE_DIR" 2>/dev/null || true
  # Prune any stale worktree metadata
  (cd "$REPO_DIR" && git worktree prune 2>>"$LOG_FILE") || true
}

cleanup() {
  local exit_code=$?
  set +e
  rm -f "$PROMPT_FILE" "$BUILD_LOG" "$ISSUE_BODY_FILE" "$PR_BODY_FILE"
  rm -rf "$LOCKFILE"
  cleanup_worktree
  if [ $exit_code -ne 0 ]; then
    log "ERROR: Script exited with code $exit_code"
    if [ "$_SLACK_NOTIFIED" -eq 0 ]; then
      notify_slack "danger" "Canopy Auto-Adopt Pipeline Failed (exit $exit_code)" \
        "Unexpected error in auto-adopt pipeline.\nCheck log: \`~/.local/share/canopy-auto-adopt/auto-adopt.log\`" 2>/dev/null || true
    fi
  fi
  exit $exit_code
}
trap cleanup EXIT

# --- 1. Version check ---
# Canopy loads the Claude Code VSCode extension at runtime (not the CLI directly),
# so the extension version on the Marketplace is the authoritative source.
# CLI and extension currently share version numbers via the same GitHub releases.
fetch_marketplace_version() {
  local payload response
  payload='{"filters":[{"criteria":[{"filterType":7,"value":"anthropic.claude-code"}]}],"flags":914}'
  response=$(curl -sS --max-time 30 -X POST \
    'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' \
    -H 'Accept: application/json;api-version=3.0-preview.1' \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>>"$LOG_FILE") || return 1
  echo "$response" | python3 -c '
import json, sys
d = json.load(sys.stdin)
exts = d.get("results", [{}])[0].get("extensions", [])
if not exts:
    sys.exit(1)
versions = exts[0].get("versions", [])
if not versions:
    sys.exit(1)
print(versions[0]["version"])
' 2>>"$LOG_FILE" || return 1
}

if ! CURRENT=$(fetch_marketplace_version); then
  log "WARNING: Marketplace query failed, falling back to npm"
  if ! CURRENT=$(npm view @anthropic-ai/claude-code version 2>>"$LOG_FILE"); then
    log "ERROR: Failed to check version from both Marketplace and npm"
    exit 1
  fi
fi
CURRENT=$(echo "$CURRENT" | tr -d '[:space:]')
if ! [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
  log "ERROR: version check returned invalid string: '$CURRENT'"
  exit 1
fi
LAST=$(cat "$VERSION_FILE" 2>/dev/null || echo "")

# Guard: first run without initialization seeds the version instead of triggering a full pipeline run
if [ -z "$LAST" ]; then
  log "WARNING: last-version.txt not initialized, setting to $CURRENT"
  echo "$CURRENT" > "$VERSION_FILE"
  exit 0
fi

if [ "$CURRENT" = "$LAST" ]; then
  log "No update ($CURRENT)"
  exit 0
fi

# Skip marker: if a version has been permanently skipped after exhausting retries,
# don't keep retrying it every day. Advance the version tracker so the next run
# starts looking at the version AFTER the one we gave up on.
if [ -f "$STATE_DIR/skipped-${CURRENT}.txt" ]; then
  log "Version $CURRENT was previously skipped (marker exists), advancing tracker"
  echo "$CURRENT" > "$VERSION_FILE"
  exit 0
fi

log "New version detected: $LAST → $CURRENT"

# --- 2. Fetch release notes from GitHub ---
if ! RELEASE_NOTES=$(gh api "repos/anthropics/claude-code/releases/tags/v${CURRENT}" \
  --jq '.body' 2>>"$LOG_FILE"); then
  log "WARNING: No GitHub release found for v${CURRENT} — will retry next run"
  exit 0
fi

if [ -z "$RELEASE_NOTES" ]; then
  log "WARNING: Empty release notes for v${CURRENT} — will retry next run"
  exit 0
fi

# --- 3. Create isolated git worktree ---
cleanup_worktree

# Fetch all branches so we can detect an existing remote auto-adopt branch
# from a previous failed run (otherwise resume would try to push non-fast-forward)
if ! (cd "$REPO_DIR" && git fetch --prune origin 2>>"$LOG_FILE"); then
  log "ERROR: git fetch failed — cannot create worktree from latest main"
  exit 1
fi

BRANCH_NAME="auto-adopt/claude-code-v${CURRENT}"

# Resume-safe worktree creation:
#   - if origin/$BRANCH_NAME exists (previous run pushed but PR create failed),
#     use it as the starting ref so `git push` is fast-forward
#   - otherwise, start from origin/main
if (cd "$REPO_DIR" && git show-ref --verify --quiet "refs/remotes/origin/$BRANCH_NAME"); then
  log "Resuming from existing remote branch origin/$BRANCH_NAME"
  START_REF="origin/$BRANCH_NAME"
else
  # Delete any stale local branch from a previous failed run so -b can recreate it
  (cd "$REPO_DIR" && git branch -D "$BRANCH_NAME" 2>>"$LOG_FILE") || true
  START_REF="origin/main"
fi

if ! (cd "$REPO_DIR" && git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" "$START_REF" 2>>"$LOG_FILE"); then
  log "ERROR: git worktree add failed for $BRANCH_NAME"
  exit 1
fi
cd "$WORKTREE_DIR" || { log "ERROR: Cannot cd to worktree $WORKTREE_DIR"; exit 1; }

# Detect GitHub repo for gh commands — use exit code, not string matching
if ! GH_REPO=$(cd "$REPO_DIR" && gh repo view --json nameWithOwner -q '.nameWithOwner' 2>>"$LOG_FILE"); then
  log "ERROR: gh repo view failed — cannot detect GitHub repo"
  exit 1
fi
GH_REPO=$(echo "$GH_REPO" | tr -d '[:space:]')
if [ -z "$GH_REPO" ]; then
  log "ERROR: gh repo view returned empty nameWithOwner"
  exit 1
fi

# --- 4. Run Claude Code CLI for analysis & implementation ---
# -p = non-interactive print mode
# --dangerously-skip-permissions = required for unattended execution
# --model sonnet = cost-effective for automated changelog analysis
PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<'HEADER'
A new version of the Claude Code VSCode extension has been released.

## Project Context
Canopy is a macOS native app that hosts the Claude Code VSCode extension's
React webview in a WKWebView. **Canopy does not talk to the Claude CLI directly.**
It runs the extension's `extension.js` unmodified inside a Node.js subprocess
via a custom `vscode-shim` (10 JS modules in Resources/vscode-shim/) that
implements a subset of the `vscode` API. The extension (not Canopy) spawns the
Claude CLI as a child process. Canopy sits between the webview and the shim,
and between the shim and the extension's native integration points.

Important: The extension is loaded at runtime from the user's VSCode install
(`~/.vscode/extensions/anthropic.claude-code-*/`). When a user updates the
extension, Canopy picks it up automatically — unless the extension has started
using new vscode APIs or new webview message types that our shim/bridge doesn't
implement, in which case Canopy breaks until we catch up.

The changelog below is the single source of truth for both the extension and
the CLI (same repo: anthropics/claude-code). Entries prefixed with `[VSCode]`
are extension-specific and are the HIGHEST priority for Canopy.

## Task
1. Read CLAUDE.md to understand the project overview, architecture, and shim.
2. Scan the changelog below. For each entry decide:
   (a) Does this affect the extension's use of the `vscode` API? → shim change
   (b) Does this affect the webview ↔ extension message protocol? → ShimProcess
   (c) Does this affect the CLI command-line contract (flags, stream-json
       events) that the extension uses when spawning the CLI? → ShimProcess /
       ssh-claude-wrapper.sh
   (d) Does it change user-visible extension behavior Canopy mirrors (status
       bar, auth, permission mode, slash commands, themes, settings)? → Swift
   (e) Is it pure-CLI terminal-only behavior the extension never touches?
       → ignore for Canopy
   Entries marked `[VSCode]` almost always fall in (a)–(d).
3. Map findings to concrete edits:
   - New `vscode` API usage by the extension → add/extend stubs in
     Resources/vscode-shim/ (types.js, window.js, workspace.js, commands.js,
     context.js, env.js, stubs.js)
   - New webview ↔ host message types → Sources/Canopy/ShimProcess.swift
     (message routing, from-extension wrapping) and AppState.swift /
     StatusBarData.swift if status-bar-relevant
   - New CLI flags / stream-json event types the extension passes through
     → ShimProcess.swift CLI bridge, Resources/ssh-claude-wrapper.sh if the
     args the wrapper strips/forwards changed
   - New auth / permission / hooks behavior → auth patching in
     ShimProcess.swift (init_response / update_state handlers, isOnboardingDismissed, experimentGates)
   - New launcher/settings options surfaced by the extension → LauncherView.swift
     and CanopySettings.swift
   - Theme / CSS variable changes → Sources/Canopy/theme-light.css
4. If no actionable changes exist for Canopy (e.g. purely terminal CLI fixes):
   Output only "NO_ACTIONABLE_CHANGES" and stop. Do not make any edits.
5. If actionable changes exist:
   a. Implement them (prefer small, focused edits; keep to the shim layer when
      possible rather than reimplementing logic in Swift).
   b. Update related documentation:
      - CLAUDE.md — Key Source Files, Architecture, Key Learnings sections
      - README.md / README.ja.md — if user-visible behavior changed
   c. Do NOT run xcodegen or xcodebuild — the pipeline will verify the build.
   d. Output a concise summary of which changelog entries were adopted and
      which files changed.

## Changelog
HEADER
echo "$RELEASE_NOTES" >> "$PROMPT_FILE"

if ! RESULT=$(claude -p --dangerously-skip-permissions \
  --model sonnet --max-budget-usd 5 < "$PROMPT_FILE" 2>>"$LOG_FILE"); then
  log "ERROR: claude CLI failed for v${CURRENT}"
  notify_slack "danger" "Canopy · Claude Code v${CURRENT} — Pipeline Error" \
    "Claude CLI failed during changelog analysis for v${LAST} → v${CURRENT}.\nCheck log: \`~/.local/share/canopy-auto-adopt/auto-adopt.log\`"
  exit 1
fi
rm -f "$PROMPT_FILE"
PROMPT_FILE=""

# --- 5. Check if changes were made ---
if printf '%s' "$RESULT" | grep -q "NO_ACTIONABLE_CHANGES"; then
  log "No actionable changes in v${CURRENT}"
  notify_slack "good" "Canopy · Claude Code v${CURRENT} — No Changes Needed" \
    "New version released (v${LAST} → v${CURRENT}) but no actionable changes for Canopy.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|View changelog>"
  echo "$CURRENT" > "$VERSION_FILE"
  rm -f "$STATE_DIR/retry-count-${CURRENT}.txt"
  exit 0
fi

# Truncate RESULT to avoid GitHub API body size limits (65536 chars, with 5536 buffer).
# Use python3 to truncate by Unicode code points (bash ${VAR:0:N} truncates by bytes
# which can split multi-byte UTF-8 sequences).
if [ ${#RESULT} -gt 60000 ]; then
  log "WARNING: Claude output truncated from ${#RESULT} to 60000 chars"
  TRUNCATED=$(printf '%s' "$RESULT" | python3 -c 'import sys; sys.stdout.write(sys.stdin.read()[:60000])')
  FENCE_COUNT=$(printf '%s' "$TRUNCATED" | grep -c '```' || true)
  if [ $((FENCE_COUNT % 2)) -eq 1 ]; then
    RESULT="${TRUNCATED}
\`\`\`

_(output truncated)_"
  else
    RESULT="${TRUNCATED}

_(output truncated)_"
  fi
fi

# Mark untracked files as intent-to-add so `git diff --stat` sees them
git add -N . 2>>"$LOG_FILE" || true

# Check actual file changes (separate from Claude's text output)
DIFF_STAT=$(git diff --stat 2>>"$LOG_FILE") || {
  log "ERROR: git diff --stat failed in worktree"
  exit 1
}
if [ -z "$DIFF_STAT" ]; then
  log "Claude found no changes to make for v${CURRENT}"
  notify_slack "good" "Canopy · Claude Code v${CURRENT} — No Changes Needed" \
    "New version released (v${LAST} → v${CURRENT}). Claude analyzed the changelog but found no code changes needed.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|View changelog>"
  echo "$CURRENT" > "$VERSION_FILE"
  rm -f "$STATE_DIR/retry-count-${CURRENT}.txt"
  exit 0
fi

# --- 6. Build verification ---
if ! xcodegen generate 2>>"$LOG_FILE"; then
  log "ERROR: xcodegen generate failed for v${CURRENT}"
  exit 1
fi

BUILD_LOG=$(mktemp)
if ! xcodebuild -scheme Canopy -configuration Debug \
  -derivedDataPath build build > "$BUILD_LOG" 2>&1; then
  log "Build failed for v${CURRENT}"
  tail -20 "$BUILD_LOG" >> "$LOG_FILE"

  # Check retry count to prevent infinite loop
  RETRY_FILE="$STATE_DIR/retry-count-${CURRENT}.txt"
  RETRY_COUNT=$(cat "$RETRY_FILE" 2>/dev/null || echo "0")
  if ! [[ "$RETRY_COUNT" =~ ^[0-9]+$ ]]; then
    log "WARNING: Corrupt retry count '$RETRY_COUNT' in $RETRY_FILE, resetting to 0"
    RETRY_COUNT=0
  fi
  if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    log "ERROR: v${CURRENT} failed $MAX_RETRIES times, marking as skipped"
    notify_slack "danger" "Canopy · Claude Code v${CURRENT} — Giving Up" \
      "Build failed ${MAX_RETRIES} times. v${CURRENT} will be skipped permanently.\nManual intervention required.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"
    # Create skip marker instead of advancing VERSION_FILE directly — this way
    # the next run's version diff still fires (in case a fix lands in a newer
    # version), but this specific version is recognized as already skipped.
    touch "$STATE_DIR/skipped-${CURRENT}.txt"
    echo "$CURRENT" > "$VERSION_FILE"
    rm -f "$RETRY_FILE"
    exit 1
  fi
  echo $((RETRY_COUNT + 1)) > "$RETRY_FILE"

  # Check for existing issue to avoid duplicates
  EXISTING_ISSUE=$(gh issue list --repo "$GH_REPO" \
    --search "auto-adopt: Claude Code v${CURRENT} build failed" \
    --state open --json number -q '.[0].number' 2>/dev/null || echo "")

  if [ -z "$EXISTING_ISSUE" ]; then
    ISSUE_BODY_FILE=$(mktemp)
    {
      printf '## auto-adopt: Claude Code v%s — Build Failed\n\n' "$CURRENT"
      printf '### Claude'\''s Analysis\n'
      printf '%s\n' "$RESULT"
      printf '\n### Build Error (last 50 lines)\n'
      printf '```\n'
      tail -50 "$BUILD_LOG"
      printf '\n```\n\n'
      printf '### Details\n'
      printf -- '- Previous version: v%s\n' "$LAST"
      printf -- '- New version: v%s\n' "$CURRENT"
      printf -- '- Retry: %d/%d\n' "$((RETRY_COUNT + 1))" "$MAX_RETRIES"
      printf -- '- Changelog: https://github.com/anthropics/claude-code/releases\n\n'
      printf 'Auto-adopt pipeline detected actionable changes but the build failed.\n'
    } > "$ISSUE_BODY_FILE"

    if ISSUE_URL=$(gh issue create --repo "$GH_REPO" \
      --title "auto-adopt: Claude Code v${CURRENT} build failed" \
      --body-file "$ISSUE_BODY_FILE" \
      --label "auto-adopt" 2>>"$LOG_FILE"); then
      log "Created issue for build failure: $ISSUE_URL"
      notify_slack "danger" "Canopy · Claude Code v${CURRENT} — Build Failed" \
        "Auto-adopt build failed (retry $((RETRY_COUNT + 1))/${MAX_RETRIES}).\n\n<${ISSUE_URL}|View issue> · <${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"
    else
      log "ERROR: Failed to create GitHub issue for build failure"
      notify_slack "danger" "Canopy · Claude Code v${CURRENT} — Build Failed" \
        "Auto-adopt build failed (retry $((RETRY_COUNT + 1))/${MAX_RETRIES}). Issue creation also failed.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"
    fi
  else
    log "Issue #${EXISTING_ISSUE} already exists for v${CURRENT}, skipping issue creation"
    notify_slack "danger" "Canopy · Claude Code v${CURRENT} — Build Failed (retry)" \
      "Auto-adopt build still failing (retry $((RETRY_COUNT + 1))/${MAX_RETRIES}).\n\nExisting issue: <https://github.com/${GH_REPO}/issues/${EXISTING_ISSUE}|#${EXISTING_ISSUE}>"
  fi

  exit 1
fi
rm -f "$BUILD_LOG"
BUILD_LOG=""

# Clean up retry counter on success
rm -f "$STATE_DIR/retry-count-${CURRENT}.txt"

# --- 7. Create PR (build succeeded) ---
if ! git add -A 2>>"$LOG_FILE"; then
  log "ERROR: git add failed for v${CURRENT}"
  exit 1
fi

# Use per-invocation -c flags instead of `git config` to avoid writing identity
# into the repo's .git/config (which would pollute the user's local checkout).
if ! git \
  -c user.name="Canopy Auto-Adopt" \
  -c user.email="auto-adopt@canopy.local" \
  commit -m "auto-adopt: claude-code v${CURRENT}

- Auto-adopted features from Claude Code v${CURRENT}
- Build verified locally

Co-Authored-By: Claude Sonnet <noreply@anthropic.com>" 2>>"$LOG_FILE"; then
  log "ERROR: git commit failed for v${CURRENT}"
  exit 1
fi

if ! git push -u origin "$BRANCH_NAME" 2>>"$LOG_FILE"; then
  log "ERROR: git push failed for $BRANCH_NAME"
  exit 1
fi

PR_BODY_FILE=$(mktemp)
{
  printf '## Auto-adopted Changes from Claude Code v%s\n\n' "$CURRENT"
  printf 'Previous version: v%s\n\n' "$LAST"
  printf '### Claude'\''s Analysis\n'
  printf '%s\n\n' "$RESULT"
  printf '### Build Verification\nBuild passed\n\n'
  printf -- '---\n'
  printf 'Changelog: https://github.com/anthropics/claude-code/releases\n'
} > "$PR_BODY_FILE"

# Check if a PR already exists for this branch (resume path)
EXISTING_PR=$(gh pr list --repo "$GH_REPO" --head "$BRANCH_NAME" --state open \
  --json url -q '.[0].url' 2>>"$LOG_FILE" || echo "")

if [ -n "$EXISTING_PR" ]; then
  log "PR already exists for $BRANCH_NAME: $EXISTING_PR"
  PR_URL="$EXISTING_PR"
elif ! PR_URL=$(gh pr create --repo "$GH_REPO" \
  --title "auto-adopt: Claude Code v${LAST} → v${CURRENT}" \
  --head "$BRANCH_NAME" \
  --label "auto-adopt" \
  --body-file "$PR_BODY_FILE" 2>>"$LOG_FILE"); then
  log "ERROR: Branch $BRANCH_NAME was pushed but PR creation failed (check that 'auto-adopt' label exists)"
  log "Will retry on next run (resume logic will pick up existing remote branch)"
  notify_slack "warning" "Canopy · Claude Code v${CURRENT} — PR Creation Failed" \
    "Branch \`${BRANCH_NAME}\` pushed but PR creation failed. Manual intervention needed.\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"
  exit 1
else
  log "Created PR for v${CURRENT}: $PR_URL"
fi

DIFF_SUMMARY=$(printf '%s\n' "$DIFF_STAT" | head -6)
notify_slack "good" "Canopy · Claude Code v${LAST} → v${CURRENT} — PR Created" \
  "<${PR_URL}|View PR>\n\n\`\`\`\n${DIFF_SUMMARY}\n\`\`\`\n\n<${CHANGELOG_URL}/tag/v${CURRENT}|Changelog>"

# --- 8. Update version tracking ---
echo "$CURRENT" > "$VERSION_FILE"
log "Done: $LAST → $CURRENT"
