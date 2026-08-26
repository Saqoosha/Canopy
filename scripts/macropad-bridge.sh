#!/bin/bash
# Bridge a locally-attached Canopy MacroPad onto TCP so a Canopy on another
# Mac can drive it (see MacroPadDevice's remote transport).
#
# Usage:
#   ./scripts/macropad-bridge.sh              run in the foreground
#   ./scripts/macropad-bridge.sh --install    install + start a launchd agent
#   ./scripts/macropad-bridge.sh --uninstall  stop + remove the agent
#
# The Canopy running on THIS machine must have MacroPad set to Off, or it
# holds the serial port and socat gets EBUSY.
set -euo pipefail

PORT="${CANOPY_MACROPAD_BRIDGE_PORT:-8765}"
LABEL="sh.saqoo.canopy-macropad-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/canopy-macropad-bridge.log"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PRODUCT="Canopy MacroPad"

die() { echo "macropad-bridge: $*" >&2; exit 1; }

require_socat() {
  command -v socat >/dev/null 2>&1 || die "socat not found. Install it with: brew install socat"
}

# The Tailscale address, and only that. Binding 0.0.0.0 would expose a device
# that can switch panes to every network this Mac joins.
tailscale_ip() {
  local ts ip
  for ts in /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \
            /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [ -x "$ts" ] || continue
    ip="$("$ts" ip -4 2>/dev/null | head -1)" || true
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  done
  if command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | head -1)" || true
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  fi
  return 1
}

# Same ranking rule MacroPadDevice.rankedCandidates uses: match the product
# string (the one identifier this project controls, set by boot.py), then take
# the highest bInterfaceNumber, which on CircuitPython is the data port rather
# than the REPL console. Never hardcode /dev/cu.usbmodemNNNN — the suffix moves
# with the port and across reboots, which is also why this is re-run per
# connection rather than resolved once.
#
# Measured on real hardware: `ioreg -c IOSerialBSDClient -l` (querying the
# serial leaf directly) never carries "USB Product Name" or
# "bInterfaceNumber" — those properties live on ancestor IOUSBHostDevice /
# IOUSBHostInterface nodes several levels up, not on the IOSerialBSDClient
# node itself. That is exactly why MacroPadDevice.swift's rankedCandidates()
# calls IORegistryEntrySearchCFProperty with kIORegistryIterateParents rather
# than reading the property directly off the matched service. `ioreg`'s CLI
# has no "search ancestors" flag, so this queries IOUSBHostDevice instead
# (small, scoped subtree per device — not the whole registry) and walks each
# device's subtree top-down, inheriting the nearest ancestor's product name
# and interface number down to each IOSerialBSDClient leaf. That is the same
# tree relationship as the Swift parent-search, just traversed from the
# opposite end because that's what's expressible from the command line.
find_device() {
  # The script goes in -c, NOT `python3 -`: ioreg output is already on
  # stdin, and `-` would make python read its own source from there
  # instead. The product string is argv, never interpolated into the -c
  # source (an apostrophe in it would be a SyntaxError, which is what
  # issue #127 records).
  ioreg -a -r -c IOUSBHostDevice -l 2>/dev/null | python3 -c '
import plistlib, sys
product = sys.argv[1]
try:
    entries = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(1)

best = None

def walk(node, inherited_product, inherited_interface):
    global best
    node_product = node.get("USB Product Name", inherited_product)
    node_interface = node.get("bInterfaceNumber", inherited_interface)
    path = node.get("IOCalloutDevice")
    if path and node_product == product:
        interface = node_interface if node_interface is not None else 0
        if best is None or interface > best[0]:
            best = (interface, path)
    for child in node.get("IORegistryEntryChildren", []) or []:
        walk(child, node_product, node_interface)

for entry in entries or []:
    walk(entry, None, None)

if best is None:
    sys.exit(1)
print(best[1])
' "$PRODUCT"
}

run_bridge() {
  require_socat
  local ip
  ip="$(tailscale_ip)" || die "no Tailscale IPv4 address. Start Tailscale, or fix the bridge before exposing it more widely — this script will not bind 0.0.0.0."
  # Intent, not a completed action: no socket exists yet, and won't until a
  # pad is actually found below. The old wording said "listening" here,
  # which was true only once socat itself started — for however long no pad
  # is attached, it was a stale claim about a bind that never happened.
  echo "macropad-bridge: starting up; will bind $ip:$PORT once a pad is found"

  local reported_no_pad=""
  while true; do
    local dev
    if ! dev="$(find_device)"; then
      # Deliberately do not listen at all with no pad present: Canopy then
      # gets ECONNREFUSED and retries cleanly, instead of seeing a connection
      # that dies before HELLO. Logged once on entry to this state, not on
      # every 2s retry, so an unplugged pad doesn't fill the log forever.
      if [ -z "$reported_no_pad" ]; then
        echo "macropad-bridge: no pad found; not listening on $ip:$PORT"
        reported_no_pad=1
      fi
      sleep 2
      continue
    fi
    reported_no_pad=""
    echo "macropad-bridge: $dev found, listening on $ip:$PORT, waiting for a client"
    # No `fork`: the device path must be re-resolved after a re-plug, and a
    # forking socat holds its argv for the life of the process. socat opens
    # address 1 (accept) before address 2, so the serial port still stays free
    # until a client actually connects — measured against a PTY stand-in
    # (never the real pad): lsof showed no fd on the target until a client
    # connected, and opened it only then.
    #
    # `ispeed=115200,ospeed=115200`, not the shorthand `b115200`: measured on
    # this machine's socat (1.8.1.3, Darwin build) — `b115200` is rejected
    # outright with "unknown option", it is not a recognized socat option at
    # all on this build. `socat -hh` lists `ispeed`/`ospeed` as the real
    # termios option names.
    if ! socat "TCP-LISTEN:$PORT,bind=$ip,reuseaddr" "FILE:$dev,raw,ispeed=115200,ospeed=115200,nonblock"; then
      # EBUSY is the common one: the local Canopy still has MacroPad on.
      echo "macropad-bridge: socat exited non-zero (is this Mac's Canopy holding the pad?)"
      sleep 2
    fi
  done
}

install_agent() {
  require_socat
  tailscale_ip >/dev/null || die "no Tailscale IPv4 address; refusing to install an agent that cannot bind."
  mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
  # EnvironmentVariables/PATH below is required, not decorative: measured on
  # this machine, launchd's default PATH for a LaunchAgent is
  # /usr/bin:/bin:/usr/sbin:/sbin — no Homebrew prefix — so a bare `socat`
  # (from require_socat's `command -v` or the invocation in run_bridge) fails
  # with "socat not found" under launchd even though it works in every
  # interactive shell. Both Homebrew prefixes are listed since which one is
  # populated depends on the Mac's architecture.
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST_EOF
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$PLIST"
  echo "macropad-bridge: installed. Logs: $LOG"
}

uninstall_agent() {
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "macropad-bridge: uninstalled."
}

case "${1:-}" in
  --install)   install_agent ;;
  --uninstall) uninstall_agent ;;
  "")          run_bridge ;;
  *)           die "unknown argument: $1" ;;
esac
