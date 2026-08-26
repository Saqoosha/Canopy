# MacroPad remote transport — handover

The branch adds a TCP transport so a MacroPad plugged into one Mac can drive a
Canopy running on another, over Tailscale. This is the operational guide for
turning it on and the honest account of what has and has not been run.

## Topology

Both machines have a pad permanently attached — this is not "whichever Mac
happens to have the pad." The Studio (office) has pad #1; the MBP (home /
portable) has pad #2. The bridge exposes **the MBP's** pad #2 over Tailscale,
because the case it exists for is sitting at the MBP at night, driving the
Studio's Canopy through Parsec, with no way for Parsec to forward pad #2's
USB to the far end. The Studio's pad #1 is never bridged — at the office the
Studio drives it locally.

## One-time setup, on the MBP

1. Install `socat` if it is not already there: `brew install socat`.
2. From a checkout of this repo on the MBP: `scripts/macropad-bridge.sh --install`.
   This writes and bootstraps `~/Library/LaunchAgents/sh.saqoo.canopy-macropad-bridge.plist`
   (`RunAtLoad` + `KeepAlive`), binds only the MBP's Tailscale IPv4 address —
   never `0.0.0.0` — and refuses to install if `tailscale ip -4` returns nothing.
   Logs land at `~/Library/Logs/canopy-macropad-bridge.log`.
3. **The MBP's own Canopy must have MacroPad set to Off.** This is also the
   default in steady state, because the common case is driving the Studio,
   not the MBP locally. If it is left on Local, the bridge fails cleanly and
   loudly rather than fighting for the pad: Canopy's `TIOCEXCL` (set right
   after its own `open`) makes socat's `open` of the same device return
   `EBUSY`, socat exits, and the bridge log names the cause ("is this Mac's
   Canopy holding the pad?"). See Known gaps for the one ordering this
   doesn't cover.

Uninstall the MBP-side agent with `scripts/macropad-bridge.sh --uninstall`.

## One-time setup, on the Studio

The Studio never runs the bridge — it only ever runs Canopy — but it does
need to be told where to find one, or the `Use <mbp-host>` menu item stays
disabled with no obvious next step:

1. Settings → General → the MacroPad section's **Bridge address** field.
   Enter the MBP's Tailscale MagicDNS name (e.g. `mbp`), then press Return
   or click away to commit.
2. The port defaults to **8765** and can be omitted; `host:port` is also
   accepted, for a bridge installed on a non-default `CANOPY_MACROPAD_BRIDGE_PORT`.
3. Once a valid address is committed, the MacroPad menu's `Use <mbp-host>`
   item becomes selectable. Before that it reads "Use Remote (set an address
   in Settings)" and stays greyed out — the state a user following only the
   MBP steps above will land in.

## Daily switching

Exactly one Canopy should be driving a given pad at a time — see "One
transport at a time" in `CLAUDE.md`'s MacroPad learnings for why fan-out was
rejected. In practice that means: the Studio's Canopy chooses between its own
local pad #1 and reaching pad #2 over the bridge; the MBP's Canopy mostly
stays `Off` and only goes `Local` for the occasional evening working on it
directly.

| Situation | Studio Canopy | MBP Canopy |
| --- | --- | --- |
| Morning at the office, pad #1 on the Studio desk | `Use Local` | `Off` |
| Leaving the office | *(nothing)* | *(nothing)* |
| Evening at home, driving the Studio through Parsec — the common case | `Use <mbp-host>` | `Off` |
| Evening at home, working on the MBP's own Canopy — occasional | `Off` | `Use Local` |

**Leaving the office needs no action** because switching the Studio to
`Use <mbp-host>` from home releases its serial port, and the firmware blanks
pad #1 by itself. But that only happens *at the moment of the switch* — pad
#1 stays lit on an empty desk for the hours in between, which is what the
**sleep chord** (hold the two outermost keys) is for before walking out.

**The last row's two changes are order-independent.** Releasing on one side
frees the pad, and the other side's existing reconnect backoff (capped at
8 s) picks it up on its own. Switching a Canopy's source away from `Off` also
clears manual sleep on it automatically
(`MacroPadController.clearsSleep(movingTo:)`), so the pad should arrive lit
at the new destination with no keypress needed.

## What is verified, and what is not

Every one of the five checks in the original plan's loopback step is covered,
but **not by a loopback run** — a full end-to-end test was ruled out for this
branch because the only real MacroPad the agents working on it could reach
was, for the whole of this work, plugged into and actively driven by the
user's installed Canopy. Opening it a second time from a test bridge would
have produced a live split-brain against a pad someone was using at the time,
so no agent working on this branch ever opened `/dev/cu.usbmodem*`, ran
`scripts/macropad-bridge.sh`, or drove a real MacroPad over a real bridge
between two machines.

What was proven instead, each against a stand-in for the piece a real
loopback would have exercised. This is not a stronger result than a real run
— it is as strong a result as could be obtained without endangering the pad
that was in use, and it leaves the serial side of the bridge itself
unexercised: whether `raw,ispeed=…,ospeed=…` actually carries the firmware's
framing intact, whether the firmware emits `HELLO` when *socat* opens the
port (Canopy's whole adoption rule depends on that being true), and whether a
re-plug is picked up on the bridge's next `accept`. None of the stand-ins
below touch the firmware at all.

| Check | How it was verified | Where |
| --- | --- | --- |
| Connect over TCP | A Python "fake pad" answering `HELLO`/`PONG` served over `socat TCP-LISTEN`, with the Debug build pointed at it | Task 4 |
| `SO_NOSIGPIPE` survives a dead bridge | A standalone Swift script isolating the exact socket-option sequence `connectSocket` uses, writing to a closed socket with and without the option set — the control run (option unset) died on `SIGPIPE`, confirming the option is what prevents it, not incidental behaviour | Task 4 |
| Reconnect with backoff | Same fake-pad harness, bridge cycled while the link was up | Task 4 |
| Device-path re-resolution | Real `ioreg` queries against the real pad (for the discovery logic itself) plus a PTY standing in for the serial device, to confirm `socat` really does defer opening the file address until a client connects (see Ruling N below) — never the TCP reconnect path against a re-plugged real pad end-to-end | Task 8 |
| Sleep clears on switching source | A logging fake pad recorded the literal command sequence (`B 0` while asleep, then `B 30` — the configured brightness — immediately on switching to a non-off source), confirming the clear fires before the first push rather than after | Task 6 |

**The pre-existing local-USB path was never exercised on this branch either,
and the table above doesn't say so.** Task 3 refactored serial discovery and
Task 4 added a new `ioctl` (`TIOCEXCL`) to it, and — for the same
already-in-use-pad reason as above — no agent on this branch ever opened
`/dev/cu.*`. That is the path every current user actually depends on today,
and it now carries an un-run code change. Hardware-run step 1 below
(`Use Local`) is that regression test as much as it is step 1 of the remote
transitions — it needs to pass on its own merits, not just as a setup step
for step 3.

A connect attempt is bounded by `MacroPadDevice.probeTimeout` (1.5 s, the
same constant the local-USB probe loop uses) before it retries — so the
first switch to a peer that just woke (from sleep, or right after the bridge
itself starts) may take a retry or two before it lands. That is the backoff
working as designed, not a fault to debug.

**The one thing none of that proves, and the one thing left for the user to
do:** an actual MacroPad, actually bridged over an actual Tailscale link
between two actual Macs. The remaining step is the hardware run from the
original plan's Step 5 — Studio over Tailscale to the MBP's bridge, walking
these four transitions:

1. Studio → `Use Local` at the office. (Also the local-USB regression test
   named above — the first time this branch's `TIOCEXCL` change runs against
   the real pad.)
2. Leave; confirm the pad blanks itself once the Studio switches away.
3. From home, Studio → `Use <mbp-host>`; confirm the pad lights with the
   Studio's panes.
4. Studio → `Off` and MBP → `Use Local`, in either order; confirm the MBP's
   Canopy picks the pad up within its 8 s reconnect backoff cap.

## Known gaps

- **`TIOCEXCL` is one-directional, and the residual gap is the bridge-first
  order only.** Canopy's serial open sets `TIOCEXCL` immediately after
  `open`; `socat` never sets it on the descriptor it opens, and `TIOCEXCL`
  does not fail against a descriptor another process already holds — it only
  blocks a *later* opener. In the order that actually occurs — Canopy
  running continuously, socat holding no fd on the pad until a client
  connects — that is enough: Canopy-first means socat's `open` returns
  `EBUSY`, socat exits, and the bridge log names the cause. What is *not*
  covered is starting the bridge (or a hand-run `socat`) before the local
  Canopy: a `socat`-first open still lets a local Canopy join afterward, and
  the split-brain this section used to say could not exist returns. The Off
  discipline above is what prevents that ordering, not a code-side lock.
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
