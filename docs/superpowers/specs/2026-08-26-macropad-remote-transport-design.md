# MacroPad Remote Transport: Driving Canopy From a Pad on Another Mac

**Date:** 2026-08-26
**Status:** Designed, not implemented

## Problem

The MacroPad is a USB CDC serial device. `MacroPadDevice` finds it by USB product
string through IOKit and opens the resulting `/dev/cu.*`. That works only when the
pad and Canopy are on the same machine.

The actual working setup is two machines and two pads:

- **Studio** (office) — the Canopy that most work happens in. Pad #1 plugged in.
- **MBP** (home / portable) — used as a Parsec client onto the Studio most nights,
  and occasionally as a local Canopy of its own. Pad #2 plugged in.

At night, sitting at the MBP and looking at the Studio's Canopy through Parsec,
pad #2 cannot reach that Canopy at all. Parsec's USB forwarding is Windows-host
only, so the display-sharing layer offers no route.

## Goals

- Canopy can take its MacroPad link over TCP from a bridge on another Mac, reached
  over Tailscale, in addition to the existing local USB path.
- Switching between local USB and remote is a single explicit action, live, with no
  app restart on either machine.
- The pad that gets left behind ends up dark, both when the user switches away from
  it and when the user walks away before switching.
- The existing local-USB behaviour — hot-plug, reconnect, sleep chord, LED
  semantics, unread bookkeeping — is unchanged.

## Non-Goals

- **Simultaneous multi-pad fan-out.** See "Approach rejected" below.
- Closing the existing "port held by something else is indistinguishable from an
  empty desk" gap in `MacroPadStatus.Link`. Recorded as a finding, not built here.
- Any firmware change. The device side is untouched; this is a host-side transport.
- Encryption or authentication on the bridge socket. Tailscale is the trust
  boundary, and the bridge binds only to the Tailscale address.

## Approach Rejected: Multi-Transport Fan-Out

The alternative was letting one Canopy hold several pads at once (local USB plus one
or more TCP links), mirroring the same state to all of them and accepting key events
from any. It was rejected for three reasons:

1. **It does not reduce the number of daily actions.** Counting the transitions in
   the real usage pattern, fan-out saves exactly one click on one transition
   (home-R2 to home-R1) and ties on the rest.
2. **It costs a rewrite of `MacroPadController`.** The diff cache, the protocol
   version gate and the reset-loop detector are per-device; the unread tracker is
   global. They currently share one object, and splitting them is the bulk of a
   1000-line file.
3. **It widens a known gap.** `canopy.macroPadAsleep` is one boolean today. With two
   pads it becomes a map, and a dark pad becomes ambiguous between "asleep" and
   "disconnected, blanked by its own firmware" — doubling the surface of issue #147,
   whose whole complaint is that sleep has no on-screen representation.

Single-active-transport also gets something for free that fan-out does not: the
firmware blanks itself when its host disconnects ("Device owns blanking; host owns
colour"), so switching away darkens the abandoned pad with no code and no user
action.

## User-Visible Behaviour

Steady state: the bridge is installed on the MBP as a launchd agent and is never
touched again. The MBP's own Canopy sits at `Off` by default, because the common
case is driving the Studio.

| Situation | Action | Where |
| --- | --- | --- |
| Morning, arriving at the office | Studio Canopy → `Use Local` | At the Studio. **1 click** |
| Leaving the office | none | — |
| Evening at home, working on the Studio (the common case) | Studio Canopy → `Use mbp` | Through Parsec. **1 click** |
| Evening at home, working on the MBP locally (occasional) | Studio → `Off`, MBP → `Use Local` | **2 clicks, either order** |

Three properties make that table hold:

- **Leaving needs no ritual.** Switching to `Use mbp` from home releases the Studio's
  USB port, and pad #1 blanks itself.
- **The order of the two-click case does not matter.** Releasing on one side frees
  the port; the other side's existing `scheduleRetry` backoff (capped at 8 s) picks
  it up on its own.
- **Mistakes are self-correcting and visible.** Carrying the MBP to the office with
  the Studio still set to `Use mbp` means the Studio reaches the pad in the bag —
  but the pad on the desk stays dark, which is noticed immediately, and `Use Local`
  fixes it.

Between leaving the office and switching at home there is a window of hours where the
Studio still holds pad #1 and it is still lit on an empty desk. That window is what
the **existing sleep chord** is for: hold the two outermost keys before walking out.
Automatic blanking covers "after the switch"; the chord covers "before the switch".
The two do not overlap and both are needed.

## Design

### 1. Selection model

`CanopySettings.macroPadEnabled: Bool` is **replaced** by `macroPadSource`, an enum
of `off` / `local` / `remote`. Keeping the boolean alongside a source would give two
ways to spell "off". The old key is read once on load and mapped (`true` → `.local`,
`false` → `.off`), then never written again — the same migration shape
`SessionTitleStore` uses.

The bridge address is a separate key, `macroPadRemoteHost: String` (`mbp`, or
`mbp:8765`; the port defaults to 8765 when omitted). Keeping *where* separate from
*which* is what lets the menu switch with one click without re-typing an address.

Validation happens at the boundary: the Settings field parses on commit and refuses
to store an unparseable value, showing the reason inline. The settings file is
hand-editable, so `load` validates too — an invalid stored value logs a warning and
degrades to `.off`. It deliberately does **not** degrade to `.local`: silently
connecting to a different pad than the one configured is the worst outcome available.

### 2. Transport abstraction

Everything from `adopt` onward in `MacroPadDevice` is already transport-agnostic —
the `fd`, the `DispatchSourceRead`, `writeBytes`'s EAGAIN loop and
`MacroPadLineDecoder` all work unchanged on a socket. Only the two entry points are
serial-specific. So the split goes exactly there:

```swift
enum Endpoint {
    case serial(path: String, interfaceNumber: Int)
    case tcp(MacroPadRemoteEndpoint)
}
```

- `rankedEndpoints()` — `.local` runs the existing IOKit scan mapped to `.serial`;
  `.remote(e)` returns `[.tcp(e)]`; `.off` returns `[]`.
- `openAndProbe(_:)` — `.serial` keeps `open` + `configureTTY`; `.tcp` calls the new
  `openTCP`. **The probe loop itself is shared verbatim**, so a TCP pad is adopted by
  the same `HELLO`/`PONG` rule as a USB one.
- `adopt(handle:label:pending:)` — the `path:` parameter becomes `label:` so logs
  read `mbp:8765` for a TCP link.

`setEnabled(_:)` becomes `setSource(_:)`. On `queue`, and only when the value
changed: send `R`, `closePort(notifying: true)`, arm or disarm the IOKit matching
notification depending on the new mode, reset `retryDelay` to 1, `attemptConnect()`.
Both arm/disarm functions already exist and are called as-is.

In remote mode the IOKit matching notification is never armed, so `hasHotplug` stays
false and the existing `scheduleRetry()` chain is what keeps discovery alive — the
fallback path that already exists for a failed arm.

### 3. Socket options

Four are load-bearing, and the first is not optional.

| Option | Why |
| --- | --- |
| `SO_NOSIGPIPE` | A write to a hung-up tty returns `EIO`; a write to a closed **socket** raises SIGPIPE and kills Canopy. Without this, stopping the bridge crashes the app. |
| `TCP_NODELAY` | Commands are ~10 bytes. Nagle would coalesce colour updates behind delayed ACKs. |
| `SO_KEEPALIVE` + `TCP_KEEPALIVE`/`TCP_KEEPINTVL` = 15, `TCP_KEEPCNT` = 3 | Closing the MBP's lid leaves the connection half-open. Writes keep succeeding into the send buffer, so the controller's watchdog ping cannot detect it. ~45 s to detection, matching SSH remote's `ServerAliveInterval=15` / `ServerAliveCountMax=3`. |
| `O_NONBLOCK` retained | Keeps `writeBytes` and the read source working with no changes. |

Connect is non-blocking: `connect` → `EINPROGRESS` → `poll(POLLOUT)` bounded by the
existing `probeTimeout` → `getsockopt(SO_ERROR)`. The poll checks `stopRequested`
each iteration, for the same reason the probe loop does: `stop()` cannot preempt
`queue`, it can only wait its turn.

**Known bound:** `getaddrinfo` blocks and runs on `queue`, and `stop()` blocks the
main thread on `queue.sync`. A hung DNS lookup therefore lengthens Cmd+Q. Tailscale
MagicDNS resolves locally, and failures are fast, so this is accepted rather than
engineered around. If it is ever observed, the fix is to move resolution off the
synchronous path — not to shorten the timeout.

### 4. Sleep

When `setSource` moves to anything other than `.off`, the controller calls
`setAsleep(false)`. Rationale: the chord means "go dark", the selector means "I am
using this one now" — different verbs, so the newer explicit one wins. Without this,
every transition would cost a swallowed keypress to wake the arriving pad.

`isAsleep` stays a single boolean under `canopy.macroPadAsleep`. Only one pad is ever
connected, so a per-device map would model something that cannot happen.

### 5. Status

`MacroPadStatus.Link` is **unchanged**: `.off` maps to `.disabled`, retrying maps to
`.searching`, adopted maps to `.connected`. Since only one transport is live at a
time, the existing "cannot tell a busy port from an empty desk" gap is not widened.

Closing that gap by adding a `.busy` case, fed from `openAndProbe`'s `EBUSY` branch,
is a real improvement and is recorded as a finding. It is out of scope here.

### 6. Menu

A `MacroPad` submenu with `Off` / `Use Local` / `Use <host>`, checkmarked on the
current source. The third item is `.disabled` when no host is configured. No key
equivalent — the shortcut space is already dense and nothing here is urgent enough to
risk a collision.

### 7. Bridge

`scripts/macropad-bridge.sh`, with `--install` / `--uninstall` and a default run mode:

```
while true:
  DEV = the callout device from `ioreg -a -r -c IOSerialBSDClient -l` whose
        "USB Product Name" is "Canopy MacroPad", highest bInterfaceNumber
  if no DEV: sleep 2; continue          # do not even listen
  socat TCP-LISTEN:$PORT,bind=$TS_IP,reuseaddr FILE:$DEV,raw,b115200,nonblock
  # socat exits when the client disconnects -> loop, re-resolving DEV
```

The ranking rule is deliberately the same one `MacroPadDevice.rankedCandidates` uses,
so console-vs-data is decided identically on both sides.

**`fork` is deliberately not used**, for two reasons. `/dev/cu.usbmodemNNNN` moves
when the pad is re-plugged, so the device path must be re-resolved per connection,
and a forking socat holds its argv for the life of the process. And the property that
motivated `fork` in the first place — the serial port staying free until a client
actually connects — holds without it, because socat opens address 1 (accept) before
address 2. This was measured, not assumed: with a PTY standing in for the pad,
`lsof` held no fd on the PTY before a client connected to the TCP-LISTEN socat, and
held it only once one had. That establishes the ordering for this machine's socat
build against a PTY stand-in, not a claim about every socat or about the real pad.

Not listening at all when no pad is present is a deliberate choice over accepting and
immediately dropping: Canopy gets `ECONNREFUSED` and retries cleanly, instead of
seeing a connection that dies before `HELLO`.

Other details: bind to the address from `tailscale ip -4`, and exit with an error if
there is none — **never** fall back to `0.0.0.0`. `--install` writes
`~/Library/LaunchAgents/sh.saqoo.canopy-macropad-bridge.plist` with `RunAtLoad` and
`KeepAlive` and bootstraps it into `gui/$UID`; logs go to
`~/Library/Logs/canopy-macropad-bridge.log`. A missing `socat` is named explicitly
rather than failing as a generic command-not-found.

### 8. Exclusivity is opt-in, and Canopy has to ask for it

An earlier draft of this spec claimed `/dev/cu.*` is opened exclusively by the
OS, so two Canopys could never drive one pad and there was no split-brain to
design around. That is false, and it was caught by implementation rather than
by reasoning. Measured with Canopy holding `/dev/cu.usbmodem20103`: a second
`open(O_RDWR|O_NONBLOCK|O_NOCTTY)` from another process **succeeds**.
Exclusivity on a BSD tty is opt-in via `ioctl(fd, TIOCEXCL)`, and Canopy had
never set it.

The claim looked corroborated by something true: `EBUSY` really is the most
common bring-up state, and CLAUDE.md says so. But that is because `screen` sets
`TIOCEXCL` itself — the OS was never the thing enforcing it.

Left alone, this makes the daily procedure fail silently instead of loudly.
With the bridge Mac's Canopy still on `.local`, socat opens the pad too; two
readers then split the key-event stream between them at random and two writers
interleave colour commands — exactly the split-brain this section used to say
could not exist.

So `openAndProbe`'s serial branch sets `TIOCEXCL` immediately after a
successful `open`. Canopy-first then behaves the way the rest of this spec
assumes: socat's open fails with `EBUSY`, and the bridge script names the
cause.

**The fix is one-directional, and the residual gap is real.** socat never sets
`TIOCEXCL`, and `TIOCEXCL` does not fail against a descriptor another process
already holds — so if socat opens the pad first, Canopy can still join it and
the split-brain returns. What is fixed is the common case: the local Canopy
runs continuously and the bridge's socat opens the port only once a client
connects. Starting the bridge before Canopy is the uncovered order.

This is still why the bridge Mac's Canopy must be at `Off` for the bridge to
reach its pad — but that toggle is now enforced by a real error rather than by
an assumption.

## Testing

**Probe (`_SidebarLogicProbe`, DEBUG):** `MacroPadRemoteEndpoint` parsing — host
alone yielding the default port, `host:port`, bracketed IPv6, empty, whitespace-only,
port 0, port 65536, non-numeric port. Source derivation — `.remote` with an empty
host degrading to `.off` rather than `.local`. And that a `setSource` to a non-`.off`
value clears the sleep flag. `EXPECTED_ASSERTIONS` in `ci.yml` is raised to match.

**Loopback end-to-end, one machine, no Studio needed:** run the bridge on the MBP and
point that same machine's Debug build at `127.0.0.1:8765`, with the pad plugged into
the MBP. This exercises the whole TCP path — `SO_NOSIGPIPE` by stopping the bridge
with the link up, reconnect backoff, device-path re-resolution by unplugging and
re-plugging the pad mid-session, the sleep-clear on switch, and whether socat really
does leave the serial port free until a client connects.

**On hardware:** Studio over Tailscale to the MBP's bridge, then the four transitions
in the behaviour table.

## Files

| File | Change |
| --- | --- |
| `Sources/Canopy/MacroPad/MacroPadRemoteEndpoint.swift` | New. Address parser plus the source value type; pure, probe-reachable. |
| `Sources/Canopy/MacroPad/MacroPadDevice.swift` | `Endpoint` split, `openTCP`, `setSource`. The bulk of the work. |
| `Sources/Canopy/MacroPad/MacroPadController.swift` | Observe the source; clear sleep on switch. |
| `Sources/Canopy/CanopySettings.swift` | `macroPadSource` + `macroPadRemoteHost`, migration off `macroPadEnabled`. |
| `Sources/Canopy/SettingsView.swift` | Picker plus a validating address field. |
| `Sources/Canopy/CanopyApp.swift` | `MacroPad` submenu. |
| `Sources/Canopy/_SidebarLogicProbe.swift`, `.github/workflows/ci.yml` | Assertions and the floor. |
| `scripts/macropad-bridge.sh` | New. |
| `CLAUDE.md` | MacroPad section. |

## Findings (out of scope, for later)

- **`MacroPadStatus.Link` cannot distinguish a busy port from an empty desk.**
  Pre-existing and already documented on the type, but this feature makes it much
  easier to hit, since forgetting the MBP-side toggle lands there every time. A
  `.busy` case fed from `EBUSY` would close it.
- **`getaddrinfo` on the queue that `stop()` waits for** — see the bound in §3.
- **Issue #147 (manual sleep has no on-screen representation)** is untouched and
  still applies; a dark pad with a healthy link indicator remains inexpressible.
