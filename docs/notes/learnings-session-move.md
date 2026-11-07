# Session move

Moving a live session to another folder: the `move-session` skill, `canopyctl move`, `move_session`, `ShimProcess.requestMove`, `SessionMove`, `SessionStore.finishMove`. Why it exists and what was measured: `docs/superpowers/specs/2026-11-06-no-folder-session-design.md`.

- **`set_cwd` is a stream-json control request, and the shim writes it.** The extension has `Query.setCwd` and never calls it. The wire and the answers are in `Resources/vscode-shim/cli-control.js` and `SessionMove.parseReply`. The key is `path`, not `cwd`. The CLI moves the transcript itself.
- **`/cd` does not help.** It is TUI-only: stream-json answers `/cd isn't available in this environment.`
- **The restart is required.** After `set_cwd` alone the next turn works, but a webview reload hangs on `Loading...`, because the shim and the extension still hold the old folder. `SessionStore.finishMove` restarts the session the way `moveToCheckout` does.
- **Nothing moves during a turn.** The skill asks from inside one, so `requestMove` latches and `moveWhenQuiet` waits on `restartLosesWork`, for `set_cwd` and again for the restart. Each `result` tries again. The CLI still answers `busy` right after a turn, which is what `busyRetryLimit` covers.
- **`needs_trust` is the normal path on a first move.** Few folders are trusted, because Canopy's launch path shows no trust dialog. The CLI remembers an answer, so it is once per folder.
- **The trust answer stays off the control socket.** Any local connection can `subscribe`, so a frame to the GUI and a verb back would let a session approve its own folder. `SessionMove.askTrust` raises a `CFUserNotification` from the daemon instead, and the answer arrives through that API alone. Keep it that way: no trust argument on `move_session`.
- **The GUI follows `moveCount`, not `cwd`.** `followsCheckoutMove` stays as it is, because one path spelled two ways must not restart a pane.
- **What a typed-in composer loses:** the restart rebuilds the webview, so text typed between the end of the turn and the move is gone (spec, 判断).
