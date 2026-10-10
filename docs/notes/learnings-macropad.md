# Learnings: MacroPad

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`. Firmware repo (https://github.com/Saqoosha/Canopy-MacroPad) is primary for device behaviour; constants in `SessionActivity.swift` are hardware measurements, so do not re-derive them.

- **Serial (CDC), never HID; Canopy must stay unsandboxed** — otherwise `/dev/cu.*` access and the design break.
- **Find the port by product string `"Canopy MacroPad"`, then prove it with `HELLO`/`PONG`; never match the product id or hardcode the path** — the id fails closed like a bad cable; the console port shares the product string but only echoes `P`.
- **`HELLO` means "cached LED state void" (full re-push); `HELLO <ver> 0` is legitimate (NeoKey unwired)** — hold the connection and draw nothing; a `count > 0` guard once addressed nonexistent keys.
- **A missing protocol version means 1** — v1 firmware has no `S`; the gate degrades breathing to a steady colour.
- **The outbound diff cache keys on the whole command** — a colour-only key swallows period/floor changes.
- **Validate `K` lines strictly** (length per line, exactly two fields, non-negative index, state 0 or 1) — a forged line could move the focused pane.
- **Do not decide `fullPush`/`R` by argument; read firmware `code.py`** — the decision flipped three times on plausible reasoning.
- **Send full-scale colours and let `B` dim** — pre-dimmed colours quantise and drift in hue.
- **`working`/`background`/`unread` are tuned as a set; `idle` is white-balanced** — retune on hardware, never one in isolation (see `ledColor`).
- **`SessionActivity.error` is effectively unreachable for local sessions** — the crash closure `Detail.swift` passes to `SessionContainer` closes the pane at once; left alone deliberately.
- **`makeFirstResponder` on the current first responder is a no-op** — so `MacroPadController.focusPane` also calls `SessionStore.focusFocusedPaneComposer()` unconditionally. The `ComposerFocusScript` selector `[role="textbox"][contenteditable]` needs both halves (either alone matches permission-box or Monaco inputs).
- **Pad press activation under Arc needs `retireStaleCurrentEvent`** — a stale hot-key `currentEvent` makes `NSApp.activate` get rejected by the WindowServer.
- **Unread clears only when all four hold** — last-interacted session (by UUID, not pane index), interaction newer than the mark (`markSeq`), recent presence (pad presses count; `CGEventSource` can't see them), and `isAppActive`. Each earlier subset failed on hardware; the ordering clause is what lets "send prompt, walk away" show green. The interaction stamp must not depend on a focus change.
- **`MacroPadController.refresh` writes `unreadSessionIds` behind an inequality guard** — `@Observable` notifies on every assignment and the write is inside the tracked closure, so it would spin.
- **Sleep is a gesture** — no OS signal exists for a monitor switched off at its own button.
- **One transport (local OR remote) at a time; do not build fan-out** — it would make a dark pad ambiguous between asleep and disconnected. Rationale: `docs/superpowers/specs/2026-08-26-macropad-remote-transport-design.md`.
- **All keys red = the pad's firmware crashed; one key red = that session errored** — the firmware paints red itself only on its own exception.
