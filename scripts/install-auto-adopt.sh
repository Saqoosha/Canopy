#!/usr/bin/env bash
# Install the auto-adopt launchd agent.
#
# Renders sh.saqoo.canopy.auto-adopt.plist.template into a concrete plist with
# the current checkout's absolute path and $HOME, writes it to
# ~/Library/LaunchAgents/, and loads it with launchctl.
#
# Re-running this script is safe — it unloads any previously loaded agent
# before reloading, so it doubles as an "update" command.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SCRIPT_DIR/sh.saqoo.canopy.auto-adopt.plist.template"
LABEL="sh.saqoo.canopy.auto-adopt"
TARGET_DIR="$HOME/Library/LaunchAgents"
TARGET="$TARGET_DIR/$LABEL.plist"
STATE_DIR="$HOME/.local/share/canopy-auto-adopt"

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found: $TEMPLATE" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR" "$STATE_DIR"

# Escape characters that have special meaning in sed's replacement string
# (\, &, and the delimiter |) so that repo paths or $HOME containing any of
# them cannot break the substitution or inject sed commands.
escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}
REPO_DIR_ESC=$(escape_sed_replacement "$REPO_DIR")
HOME_ESC=$(escape_sed_replacement "$HOME")

# Substitute placeholders. Use | as sed delimiter since paths contain /.
sed \
  -e "s|__CANOPY_REPO__|$REPO_DIR_ESC|g" \
  -e "s|__HOME__|$HOME_ESC|g" \
  "$TEMPLATE" > "$TARGET"

# Validate the rendered plist
if ! plutil -lint "$TARGET" >/dev/null; then
  echo "ERROR: rendered plist is invalid:" >&2
  plutil -lint "$TARGET" >&2 || true
  exit 1
fi

# Reload: unload if present, then load
launchctl unload "$TARGET" 2>/dev/null || true
launchctl load "$TARGET"

echo "Installed $TARGET"
echo "Loaded launchd agent: $LABEL"
echo ""
echo "Next steps:"
echo "  1. Seed last-version: echo <current-version> > ~/.local/share/canopy-auto-adopt/last-version.txt"
echo "  2. (Optional) Configure Slack webhook:"
echo "     echo <webhook-url> > ~/.local/share/canopy-auto-adopt/slack-webhook-url.txt"
echo "  3. Trigger manually to test:"
echo "     launchctl start $LABEL"
echo "     tail -f ~/.local/share/canopy-auto-adopt/auto-adopt.log"
