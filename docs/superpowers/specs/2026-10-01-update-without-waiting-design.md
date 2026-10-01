# Updates that do not wait forever

## Goal

After an app update, the Canopy Server daemon keeps running the old build until
no session would lose anything (`ShimProcess.upgradeBlocker`). After a Claude
Code extension update, every running shim keeps the old extension until its
session is restarted. In both cases the user cannot see that anything is
waiting, or why, and the only way forward is to close sessions by hand.

Measured on 2026-10-01 (3.0.4): this Mac waited about 5 minutes on a running
turn and on a studio pane that was viewing one of its sessions. The reasons
were written only to the unified log.

This spec makes three changes:

- **A.** A remote client (another Mac's mirror pane, the phone) that can
  re-attach on its own no longer blocks the daemon restart.
- **B.** The GUI shows a pending daemon update, which sessions hold it and why,
  and offers **Restart now**.
- **(3)** The same GUI surface lists sessions still running an older extension
  than the one installed, with a per-session restart.

Out of scope:

- Swapping the daemon one session at a time (option C).
- **Restart now** on the phone.
- Restarting sessions automatically when an extension update lands.

## A. Remote clients re-attach after a daemon restart

### Today

- `MirrorServer.announceRestart()` sends `daemon_restarting` to every attached
  connection, then closes both listeners.
- `MirrorClient` sets `expectsRestart` when it reads that frame.
- On the drop that follows, `MirrorPaneView` re-attaches only when `isDaemon` is
  true, which means a pane on this Mac talking to this Mac's daemon.
- A pane on another Mac shows `.reconnectFailed` and waits for Retry. The phone
  shows its failed screen.
- So `upgradeBlocker` treats any non-local client as something a restart would
  break: "a phone or another Mac is attached".

### Change

1. **Capability.** A client that can re-attach by itself adds
   `"restart": true` to its `attach` line. `MirrorServer` stores it on the
   connection as `reattachesAfterRestart`. The flag works the same way as
   `status`, `usage`, `compress` and `images`.
2. **Blocker.** The remote-client clause in `upgradeBlocker` counts only
   connections that are neither local nor `reattachesAfterRestart`. An old
   phone or an old Mac still blocks, exactly as today, so there is no version
   skew to handle.
3. **Mac remote pane.** When `expectsRestart` is set, a non-daemon mirror pane
   re-attaches after the drop: the same `SessionStore.restartSession(_,
   notifyDaemon: false)` call that Retry makes, every 2 s for up to 60 s,
   until an attach succeeds. During that time the connection overlay says
   "Reconnecting — \<machine\> is restarting for an update". If 60 s pass
   without an attach, the pane falls back to today's `.reconnectFailed` with
   Retry. The 60 s budget is meant to cover launchd's restart plus the new
   daemon restoring its sessions. It is a guess: the announcement-to-listener
   time has not been measured, and step 1 measures it before the number is
   fixed.
   - A refusal (`attach_error`) during the loop ends it at once, because the
     new daemon answered and said no.
   - Every attempt runs on the main actor and checks that the session is still
     in `.reconnectFailed`. A pane the user closed or retried by hand stops the
     loop.
4. **Phone (Canopy-Mobile, its own PR).** The phone sends `"restart": true`,
   treats `daemon_restarting` as "expect a drop", and on that drop re-attaches
   with the same 2 s / 60 s budget, reusing the rebuild path it already has for
   returning from the background (`MirrorLiveView.reattach`). It shows
   "Reconnecting…" rather than the failed screen. The Canopy side does not
   depend on this PR: until the phone ships it, a phone simply keeps blocking.

### What still blocks

Everything else in `upgradeBlocker` is unchanged: a running turn, a question or
permission prompt, a background task, an in-flight keep-alive or recap, a
queued phone reply, an unsent first prompt, and a watched session with no
transcript. A restart would lose each of these, and **Restart now** (B) is how
the user overrides them.

## B. Pending update in the GUI, with Restart now

### Daemon side

- The upgrade check (`DaemonDelegate.restartIfUpgraded`, run by
  `upgradeTimer`) already computes the on-disk build and a blocker. It now
  collects **every** blocked session instead of stopping at the first, and
  publishes the result as one value:

  ```text
  UpgradeState {
    runningBuild: String
    pendingBuild: String?          // nil when the build on disk is the running one
    heldBy: [Hold]                 // empty when nothing holds the restart
    notUnderLaunchd: Bool          // a restart could not start the new build
    extension: ExtensionState?     // see (3)
  }
  Hold { key, title, reason }      // key = OpenSession.id, as in session_state
  ```

- Control subscribers receive it as an `upgrade_state` line, pushed the same
  way `session_state` is: on `subscribe` and whenever the value changes. The
  value is a pure function of its inputs, so the probe can test it.
- A new control verb, `restart_now`, is accepted from local clients only. It
  runs the restart path that `restartIfUpgraded` runs today (announce, stop
  shims, `exit(1)`) without checking blockers. It is refused when no build is
  pending, and when the daemon was not started by launchd (nothing would start
  the new build).
- A refused or impossible restart replies with an error. It never exits.

### GUI side

- `ControlClient` gains `onUpgradeState`. The value lives in an observable
  store that the sidebar reads.
- The sidebar footer (the version row, beside `MacroPadIndicator`) shows one
  line while anything is pending:
  - "Update ready — waiting for 2 sessions" when a daemon build is pending and
    held.
  - "Update ready — restarting…" from **Restart now** until the GUI reconnects
    to the new daemon.
  - "Extension 2.1.290 — 3 sessions on older versions" when only (3) applies.
- Clicking the line opens a popover listing each hold (session title and
  reason) and a **Restart now** button.
- **Restart now** asks for confirmation first, naming the sessions whose work
  will be interrupted, for example "2 sessions are working. Restarting stops
  their current turns. Their conversations are kept." When there are no holds,
  the daemon is already restarting by itself and the button does not appear.
- Local panes need no new code. They already receive `daemon_restarting` and
  re-attach. A turn interrupted by the restart is lost the way a quit loses
  it; the conversation resumes from its transcript.

## (3) Sessions on an older extension

- `ShimProcess` records the extension version it started with: the
  `package.json` version of the folder it passed as `--extension-path`.
- The daemon adds `ExtensionState` to `UpgradeState`:

  ```text
  ExtensionState {
    installed: String              // CCExtension.extensionVersion()
    stale: [Stale]                 // live shims whose version != installed
  }
  Stale { key, title, running, blocker: String? }
  ```

  The installed version is read on each upgrade check, so an extension the
  updater installs while the daemon runs shows up within one check interval.
  The daemon is the reader, because it owns the shims, so a GUI that updated
  the extension and a daemon that did not see the same answer.
- Each row in the popover has a **Restart** button that sends the existing
  `restart_session` verb, which restarts the shim with the same resume id. The
  new shim picks the newest extension, because `CCExtension.extensionPath()`
  already does.
- A row whose session is busy (`blocker` set) shows the reason, and its button
  asks for the same confirmation as **Restart now**.
- The restart also lets `ExtensionCleanup.removeUnused()` delete the old
  version, at the daemon's next start or the next install.

## Testing

**Probe (pure functions):**

- `UpgradeState` assembly: no pending build gives an empty state; several
  holds come back in session order; launchd absence is reported.
- The blocker predicate for remote clients, in a table: local, remote with
  `restart`, and remote without it.
- `ExtensionState`: equal versions give no stale rows; a stale row carries its
  blocker.
- `restart_now` refusal rules: no pending build, and not under launchd.
- Parsing the `restart` capability on `attach`.

**On device:**

- A remote pane on studio viewing a session on this Mac. Install a new build
  here: the daemon restarts without waiting for the pane, and the studio pane
  re-attaches by itself.
- A running turn holds the update. The footer names the session; **Restart
  now** asks for confirmation and then swaps the daemon, and the session
  resumes from its transcript.
- An extension update with two sessions open: both are listed, and **Restart**
  moves each one to the new version.

## Order of work

1. A (Canopy): the capability, the blocker change, and the Mac remote pane
   re-attach.
2. B: `UpgradeState`, `upgrade_state`, `restart_now`, and the footer.
3. (3): the extension version per shim, and its rows in the same popover.
4. The phone, in Canopy-Mobile, at any point after step 1.

Each step can ship as its own PR. Steps 2 and 3 share the popover, so step 3
lands after step 2.
