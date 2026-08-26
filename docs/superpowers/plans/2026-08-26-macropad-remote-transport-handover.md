# MacroPad remote transport — handover

The branch adds a TCP transport so a MacroPad plugged into one Mac can drive a
Canopy running on another, over Tailscale. This is the operational guide for
turning it on and the honest account of what has and has not been run.

## One-time setup, on the Mac the pad is physically plugged into

1. Install `socat` if it is not already there: `brew install socat`.
2. From a checkout of this repo on that Mac: `scripts/macropad-bridge.sh --install`.
   This writes and bootstraps `~/Library/LaunchAgents/sh.saqoo.canopy-macropad-bridge.plist`
   (`RunAtLoad` + `KeepAlive`), binds only that Mac's Tailscale IPv4 address —
   never `0.0.0.0` — and refuses to install if `tailscale ip -4` returns nothing.
   Logs land at `~/Library/Logs/canopy-macropad-bridge.log`.
3. **That Mac's own Canopy must have MacroPad set to Off.** The bridge and a
   local Canopy both want the serial port; Canopy does not set `TIOCEXCL`
   ahead of the bridge in a way that excludes it (see Known gaps), so a local
   Canopy left on Local can and will fight the bridge for the pad rather than
   failing cleanly.

Uninstall with `scripts/macropad-bridge.sh --uninstall`.

## Daily switching

The pad drives whichever Canopy currently has it. Exactly one Canopy should
be `Local` or pointed `Remote` at the bridge at a time — see "One transport at
a time" in `CLAUDE.md`'s MacroPad learnings for why fan-out across both was
rejected.

| Situation | Studio (pad's usual desk) | MBP (or wherever else Canopy runs) |
| --- | --- | --- |
| At the office, pad on the Studio | `Use Local` | — |
| Leaving the office | *(leave as-is)* | — |
| At home, working through the MBP against the Studio's bridge | `Off` | `Use <studio-host>` |
| Back at the office, working locally again | `Use Local` | `Off` |

Only the side actually being used needs to change; the other can be left
alone or set explicitly — either order works, since each Canopy reconnects
independently. Switching a Canopy's source away from `Off` clears manual
sleep on it automatically (`MacroPadController.clearsSleep(movingTo:)`), so
the pad should arrive lit at the new destination with no keypress needed.

## What is verified, and what is not

Every one of the five checks in the original plan's loopback step is covered,
but **not by a loopback run** — a full end-to-end test was ruled out for this
branch because the only real MacroPad in existence was, for the whole of this
work, plugged into and actively driven by the user's installed Canopy. Opening
it a second time from a test bridge would have produced a live split-brain
against a pad someone was using at the time, so no agent working on this
branch ever opened `/dev/cu.usbmodem*`, ran `scripts/macropad-bridge.sh`, or
drove a real MacroPad over a real bridge between two machines.

What was proven instead, each against a stand-in for the piece a real
loopback would have exercised:

| Check | How it was verified | Where |
| --- | --- | --- |
| Connect over TCP | A Python "fake pad" answering `HELLO`/`PONG` served over `socat TCP-LISTEN`, with the Debug build pointed at it | Task 4 |
| `SO_NOSIGPIPE` survives a dead bridge | A standalone Swift script isolating the exact socket-option sequence `connectSocket` uses, writing to a closed socket with and without the option set — the control run (option unset) died on `SIGPIPE`, confirming the option is what prevents it, not incidental behaviour | Task 4 |
| Reconnect with backoff | Same fake-pad harness, bridge cycled while the link was up | Task 4 |
| Device-path re-resolution | Real `ioreg` queries against the real pad (for the discovery logic itself) plus a PTY standing in for the serial device, to confirm `socat` really does defer opening the file address until a client connects (see Ruling N below) — never the TCP reconnect path against a re-plugged real pad end-to-end | Task 8 |
| Sleep clears on switching source | A logging fake pad recorded the literal command sequence (`B 0` while asleep, then `B 30` — the configured brightness — immediately on switching to a non-off source), confirming the clear fires before the first push rather than after | Task 6 |

**The one thing none of that proves, and the one thing left for the user to
do:** an actual MacroPad, actually bridged over an actual Tailscale link
between two actual Macs. The remaining step is the hardware run from the
original plan's Step 5 — Studio over Tailscale to the MBP's bridge, walking
these four transitions:

1. Studio → `Use Local` at the office.
2. Leave; confirm the pad blanks itself once the Studio switches away.
3. From home, Studio → `Use <mbp-host>`; confirm the pad lights with the
   Studio's panes.
4. Studio → `Off` and MBP → `Use Local`, in either order; confirm the MBP's
   Canopy picks the pad up within its 8 s reconnect backoff cap.

## Known gaps

- **`TIOCEXCL` is one-directional.** Canopy's serial open sets it, but `socat`
  never sets it on the descriptor it opens. `TIOCEXCL` also does not fail
  against a descriptor another process already holds open — it only blocks a
  *later* opener. So a `socat`-first open still lets a local Canopy join
  afterward; the flag stops the reverse ordering (Canopy first, bridge
  second) but not this one. There is no code-side lock that prevents a local
  Canopy and the bridge from both holding the port at once — the Off
  discipline above is the only thing actually preventing it.
- **The launchd agent's `PATH`** (`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`)
  covers both Homebrew prefixes (Apple Silicon and Intel) but not a MacPorts
  install (`/opt/local/bin`) or a from-source `socat` placed somewhere else.
  A `socat` on one of those paths works from an interactive shell but the
  installed agent will report "socat not found" until the plist is edited by
  hand.
- **The plist heredoc does not XML-escape the script path.** `$SCRIPT` (and
  `$LABEL`/`$LOG`) are interpolated directly into XML text and attribute
  positions. In practice these are all built from `$HOME`/`dirname`/`basename`
  and can't contain `<`, `>`, `&`, or `'` under normal use, so this has not
  caused a problem — but a repo checked out under a path containing one of
  those characters would produce a broken plist with no clear error.
