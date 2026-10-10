# Key source files

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

The per-file catalogue was dropped: open the file and read its doc comments. Only hazards that are not on the named symbol's own doc comment remain.

## Swift app

- **`SessionActivity.of(_:isUnread:)` is the only place that knows the state priority order** (`error > asking > working > background > unread > idle`) — the sidebar dot (`ActivityDot`) and the MacroPad LED both read it, so a state cannot mean different things on screen and on the pad. Do not add a second classifier.
- **`SidebarRow.isOpen` means "belongs in the Open section", not "has an `OpenSession`"** — `.launcher` rows have no session. Any consumer that needs a session must match `case .open` explicitly.
- **`SessionStore.startIfDormant(_:)` must run on every route that hands a session to a pane** (`openInFocusedPane` seed and swap branches, `openInLauncherPane`, `openInNewPane`; not the already-paned focus-only branch) — otherwise a launch-restored `.dormant` session sits in a pane with no shim.
- **The sidebar usage-bar colours (percent-of-quota or pace rule) are deliberately not shared with `StatusBarView`'s context meter** — the meter colours from the CLI's own levels; do not unify them.

## MacroPad

- **`MacroPadDevice` must set `SO_NOSIGPIPE` on the TCP path and `TIOCEXCL` on the serial path** — a write to a closed socket raises SIGPIPE and kills Canopy; without `TIOCEXCL` two processes can drive the same pad.
- **Switching `macroPadSource` in one build changes it for the other** — it lives in the `settings.json` shared by Debug and Release, read at launch. A build that must free the port for `scripts/macropad-bridge.sh` (`socat`) has to be set Off, and the other build follows on its next launch.
- **`MacroPadStatus` indicator must render in every state, `.disabled` included, because it is also the source selector** — dropping a case from `appearance(for:)` should stay a compile error (non-optional return). `env CANOPY_MACROPAD_STATUS_DEMO=1 <binary>` cycles all states.
- **`MacroPadController.focusPane` is the only caller of `focusFocusedPaneComposer()`** — other pane-navigation routes deliberately do not move the caret.

## Daemon

- **Release registers the LaunchAgent on every GUI launch; Debug only with `CANOPY_REGISTER_DAEMON=1`** (`DaemonRegistration`). Debug and Release each own an agent, keyed by bundle id.
- **The Mirror TCP port exists only while Mirror is on; Debug uses base+1** (`DaemonPaths`) — a Debug and a Release daemon on one Mac must not collide.
- **The daemon is started as a plain `Process`, never `NSWorkspace.openApplication`** (`DaemonSupervisor`, `CanopyDaemon`) — LaunchServices would register it as a second instance of `sh.saqoo.Canopy`, breaking Dock relaunch and letting Sparkle quit it.
- **A Debug build cannot reproduce the firewall drop that `MirrorRelay` works around** — the firewall matches the Debug bundle id to some other worktree copy and lets it through. A Debug E2E proves the relay switch-over only.
- **`restart_now` (`DaemonUpgrade`) overrides the upgrade blockers and is accepted from local clients only** — a remote client's `restart: true` on attach does not block an upgrade.

## Shim and wire

- **Anything in `ShimProcess` that latches (`recapRequestInFlight`, keep-alive latch, phone-reply flight) must be cleared in `resetActivityState()`** — a stale latch swallows the reconnected session's first real turn.
