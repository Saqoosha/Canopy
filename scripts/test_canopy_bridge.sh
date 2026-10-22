#!/bin/sh
# Runs the canopy-bridge mod's *.test.ts with `claude plugin test`.
# On a copy: the CLI writes tsconfig.json and .claude-plugin/types/ into the
# folder it tests, and Resources/canopy-bridge is copied into the app bundle.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R "$ROOT/Resources/canopy-bridge" "$WORK/canopy-bridge"
env -u CLAUDE_CODE_ENTRYPOINT claude plugin test "$WORK/canopy-bridge"
