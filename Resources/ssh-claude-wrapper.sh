#!/bin/bash
set -euo pipefail
# SSH Claude Process Wrapper for Canopy
#
# Called by CC extension as: wrapper [nodePath] localClaudeBinary [CLIflags...]
# We discard everything up to and including the claude binary path,
# then run "claude" on the remote host with the remaining CLI flags.
#
# Note: SSH concatenates remote args with spaces for the remote shell,
# so arguments containing spaces/quotes may not survive. This is a known
# limitation of `ssh host command args...` transport.

if [ -z "${CANOPY_SSH_HOST:-}" ]; then
    echo "Error: CANOPY_SSH_HOST not set" >&2
    exit 1
fi

# Skip args until we find one starting with "-" (a CLI flag).
# This discards the local nodePath and claudeBinary path.
while [ $# -gt 0 ]; do
    case "$1" in
        -*) break ;;
        *)  shift ;;
    esac
done

# Escape a value for safe inclusion in a single-quoted shell string.
# Turns internal single quotes into '\'' (end single-quote, escaped quote, resume).
shell_quote() {
    local s="${1//\'/\'\\\'\'}"
    printf "'%s'" "$s"
}

# Forward selected env vars to the remote machine. ShimProcess sets these
# locally, but SSH doesn't forward arbitrary env vars — without this the remote
# claude would fall back to the default Anthropic API / Sonnet, and (for
# CLAUDE_CODE_DISABLE_1M_CONTEXT) force-upgrade Opus to the 1M tier.
#
# CLAUDE_CODE_ENTRYPOINT is set to "claude-vscode" by extension.js in the env it
# spawns this wrapper with, and it is what the CLI writes into every transcript
# record. Unforwarded, the remote CLI saw it unset and stamped its own default,
# "sdk-cli" — the same mark a `claude -p` one-shot carries, and the one
# ClaudeSessionHistory reads as "automated, never show this to the user". So
# every SSH remote session was recorded on the remote as something to be
# filtered out, which is why "Continue session" could not find one even after
# RemoteSessionHistory started looking on the right machine. Measured on the
# host this was built against, and the ONE place these figures are recorded:
# a real project folder held 16 candidates — 13 /security-review runs (sdk-py)
# and 3 genuine Canopy sessions — and all 3 of the genuine ones were stamped
# sdk-cli with zero claude-vscode, so nothing in that folder was resumable.
#
# Transcripts written before this line existed still carry sdk-cli and stay
# invisible to the continue lookup; nothing here can tell them apart from a
# genuine `claude -p` run after the fact.
REMOTE_ENV=""
for var in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
           ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
           ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL \
           CLAUDE_CODE_DISABLE_1M_CONTEXT CLAUDE_CODE_ENTRYPOINT; do
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
        REMOTE_ENV="$REMOTE_ENV $var=$(shell_quote "$val")"
    fi
done

# Shell-quote every remaining CLI arg so args with spaces survive SSH.
REMOTE_ARGS=""
for arg in "$@"; do
    REMOTE_ARGS="$REMOTE_ARGS $(shell_quote "$arg")"
done

# Model/effort selection. Locally Canopy writes these to ~/.claude/settings.json,
# but the remote CLI reads the remote settings file, so the launcher selection
# never reaches it. ShimProcess passes the selection via env vars; append them
# as CLI flags, which override the remote settings.json.
if [ -n "${CANOPY_REMOTE_MODEL:-}" ]; then
    REMOTE_ARGS="$REMOTE_ARGS --model $(shell_quote "$CANOPY_REMOTE_MODEL")"
fi
if [ -n "${CANOPY_REMOTE_EFFORT:-}" ]; then
    REMOTE_ARGS="$REMOTE_ARGS --effort $(shell_quote "$CANOPY_REMOTE_EFFORT")"
fi

# Resume. The extension resolves a session off the LOCAL disk, and at a fresh
# launch passes no --resume of its own - measured on 2.1.263 by capturing this
# script's argv, and separately by reading a live local session's CLI argv
# (this script never runs for those, so its own capture says nothing about
# them). On reconnect it does pass one. Either way this script appends its own
# below, so a fresh continued session does hand the CLI a --resume. Note that is an observation about this configuration, not a property of
# the extension: extension.js builds --resume= from options Canopy DOES set, and
# what drops it is the extension's own local-disk precheck, which is skipped on
# reconnect. So on reconnect the CLI can receive two --resume flags. Measured:
# it accepts them, exits 0, and the LAST wins - which is the one appended below.
# See ShimProcess's CANOPY_REMOTE_RESUME block for the full trace.
#
# A remote session found nothing to resolve at first launch and silently began
# a fresh conversation.
#
# ShimProcess sets this only when the id names a transcript that exists; the CLI
# exits 1 on one that does not.
#
# Unlike --model/--effort above, this is gated on the spawn actually being a
# session: the extension routes EVERY claude invocation through this wrapper,
# including `claude auth status --json`, and only the session spawn passes
# --input-format. (Those other spawns are already mangled by the arg-skipping
# loop above, which drops `auth status` as non-flag words — pre-existing, and
# not something to widen by adding a resume id to it.)
#
# The pattern matches the OPENING quote only, so it covers both the separate
# form the extension uses today (`'--input-format' 'stream-json'`) and the
# equals form (`'--input-format=stream-json'`). An earlier revision spelled two
# alternatives, one of which — the unquoted `--input-format` — could never match
# because shell_quote wraps every arg, so it read as coverage it did not
# provide while the spelling that IS plausible went uncovered.
if [ -n "${CANOPY_REMOTE_RESUME:-}" ]; then
    case " $REMOTE_ARGS " in
        *" '--input-format"*)
            REMOTE_ARGS="$REMOTE_ARGS --resume $(shell_quote "$CANOPY_REMOTE_RESUME")"
            ;;
    esac
fi

# Bring our own `open`. A Canopy remote session runs the CLI on the FAR side,
# so an agent's `open report.pdf` reaches that host's LaunchServices and the
# window appears on a screen nobody is sitting at. canopy-remote-open.sh is the
# redirector and carries the whole rationale; what belongs here is how it is
# delivered.
#
# It rides IN the launch command as a heredoc rather than being copied by a
# second ssh. That buys two things: no extra round trip on every session start,
# and no stale copy to reason about - the host always runs the shim this build
# ships. PATH is prepended for that one process, so a hand-run `ssh host`, a
# local terminal on the host, and a Canopy running on the host itself all keep
# the stock `open`.
#
# The launch goes through `/bin/sh -c '<script>' canopy <args...>` instead of
# being handed to the login shell verbatim, and BOTH halves of that matter.
# `PATH="$dir:$PATH"` is only portable under sh: the Macs here log in to fish,
# where PATH is a LIST, so that same line expands to one mangled entry per
# element. And the CLI flags arrive as positional parameters instead of being
# re-parsed by the far shell, which is exactly the arg-mangling limitation
# noted at the top of this file. Measured on studio (fish) and win4090 (Git
# Bash): identical PATH, identical args, `claude` resolved on both.
#
# Every failure here is silent and lands back on the stock `open`: a redirect
# that cannot be installed must not become an `open` that does not work.
SHIM_SRC="$(cd "$(dirname "$0")" && pwd)/canopy-remote-open.sh"
REMOTE_SCRIPT=""
if [ -r "$SHIM_SRC" ] && SHIM_B64=$(base64 < "$SHIM_SRC" | tr -d '\n'); then
    # base64, and NOT a heredoc carrying the script verbatim. Measured: fish
    # collapses \\ to \ INSIDE single quotes, where sh keeps both, so a
    # shell_quote'd payload arrives two bytes short and silently altered - the
    # shim's own sed expression was the casualty. Nothing is wrong with the
    # quoting; fish simply escapes inside single quotes and sh does not. So the
    # payload is reduced to an alphabet with no quote, no backslash and no
    # newline in it, and this block deliberately contains no single quote of
    # its own either: then shell_quote has nothing to escape and every login
    # shell delivers the same bytes.
    REMOTE_SCRIPT="canopy_b64=$SHIM_B64
canopy_bin=\"\$HOME/.canopy/bin\"
mkdir -p \"\$canopy_bin\" 2>/dev/null
printf %s \"\$canopy_b64\" | base64 -d > \"\$canopy_bin/open.new\" 2>/dev/null ||
    printf %s \"\$canopy_b64\" | base64 -D > \"\$canopy_bin/open.new\" 2>/dev/null
if [ -s \"\$canopy_bin/open.new\" ] && chmod +x \"\$canopy_bin/open.new\" 2>/dev/null && mv -f \"\$canopy_bin/open.new\" \"\$canopy_bin/open\" 2>/dev/null; then
    ln -sf open \"\$canopy_bin/xdg-open\" 2>/dev/null
    PATH=\"\$canopy_bin:\$PATH\"
    export PATH
else
    rm -f \"\$canopy_bin/open.new\" 2>/dev/null
fi
"
fi
REMOTE_SCRIPT="${REMOTE_SCRIPT}exec claude \"\$@\""
# "canopy" is $0 for the script; the already-quoted flags follow as $1..$n.
REMOTE_LAUNCH="/bin/sh -c $(shell_quote "$REMOTE_SCRIPT") canopy$REMOTE_ARGS"

# cd to the remote working directory before running claude.
# The extension passes cwd via spawn options (useless over SSH),
# so we use CANOPY_SSH_CWD env var set by ShimProcess.
if [ -n "${CANOPY_SSH_CWD:-}" ]; then
    exec ssh -T -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CANOPY_SSH_HOST" "cd $(shell_quote "$CANOPY_SSH_CWD") &&$REMOTE_ENV $REMOTE_LAUNCH"
else
    exec ssh -T -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CANOPY_SSH_HOST" "$REMOTE_ENV $REMOTE_LAUNCH"
fi
