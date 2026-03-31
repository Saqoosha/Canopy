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

# cd to the remote working directory before running claude.
# The extension passes cwd via spawn options (useless over SSH),
# so we use CANOPY_SSH_CWD env var set by ShimProcess.
if [ -n "${CANOPY_SSH_CWD:-}" ]; then
    exec ssh -T -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CANOPY_SSH_HOST" "cd '$CANOPY_SSH_CWD' && claude $*"
else
    exec ssh -T -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$CANOPY_SSH_HOST" claude "$@"
fi
