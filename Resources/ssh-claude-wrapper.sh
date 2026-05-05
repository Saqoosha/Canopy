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

# Forward custom API provider env vars to the remote machine.
# ShimProcess sets these locally, but SSH doesn't forward them — the
# remote claude would fall back to the default Anthropic API / Sonnet.
REMOTE_ENV=""
for var in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
           ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
           ANTHROPIC_DEFAULT_HAIKU_MODEL CLAUDE_CODE_SUBAGENT_MODEL; do
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

# cd to the remote working directory before running claude.
# The extension passes cwd via spawn options (useless over SSH),
# so we use CANOPY_SSH_CWD env var set by ShimProcess.
if [ -n "${CANOPY_SSH_CWD:-}" ]; then
    exec ssh -T -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CANOPY_SSH_HOST" "cd $(shell_quote "$CANOPY_SSH_CWD") && $REMOTE_ENV claude$REMOTE_ARGS"
else
    exec ssh -T -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CANOPY_SSH_HOST" "$REMOTE_ENV claude$REMOTE_ARGS"
fi
