# Session move

Moving a live session to another folder: the `move-session` skill, `canopyctl move`, `move_session`, `ShimProcess.requestMove`, `SessionMove`, `SessionStore.noteMove` and `restartAfterMove`. Why it exists and what was measured: `docs/superpowers/specs/2026-11-06-no-folder-session-design.md`.

- **`set_cwd` is a stream-json control request, and the shim writes it.** The extension has `Query.setCwd` and never calls it. The wire and the answers are in `Resources/vscode-shim/cli-control.js` and `SessionMove.parseReply`. The key is `path`, not `cwd`. The CLI moves the transcript itself.
- **`/cd` does not help.** It is TUI-only: stream-json answers `/cd isn't available in this environment.`
- **The restart is required.** After `set_cwd` alone the next turn worked, but a webview reload hung on `Loading...`. A restart in the new folder fixed it, so `restartAfterMove` does what `moveToCheckout` does.
- **Two steps.** On the CLI's `ok`, `noteMove` records the new folder on the session at once, so a restart for any other reason also starts there. The restart itself waits.
- **Nothing moves while work runs.** The skill asks from inside a turn, so `SessionMove.Latch` waits on `restartLosesWork`, for `set_cwd` and again for the restart. A `result`, or a background task clearing, tries again. The CLI still answers `busy` right after a turn, which is what `busyRetryLimit` covers.
- **`needs_trust` is the normal path on a first move**, because Canopy's launch path shows no trust dialog. The CLI records an accepted answer for the whole repository, worktrees included. Cancel sends nothing, so the next move there asks again.
- **The trust answer stays off the control socket.** Any local connection can `subscribe`, so a frame to the GUI and a verb back would let a session approve a folder through Canopy. `SessionMove.askTrust` raises a `CFUserNotification` from the daemon instead. Keep it that way: no trust argument on `move_session`. This does not guard the CLI's own trust file, which a session with Bash can edit.
- **The GUI follows a rise in `moveCount`.** `followsCheckoutMove` stays as it is, because one path spelled two ways must not restart a pane. A new daemon counts from 0 again.
- **Typed text in the composer:** the restart rebuilds the webview, so text typed between the end of the turn and the move is lost. Read from the code, not measured.
- **Known gaps:** a `set_cwd` the CLI never answers keeps the move waiting, with no timeout, because a late answer after one would leave the CLI moved and Canopy not. `transcript_relocated: false` is not handled.
- **The resume writes a filler line.** `set_cwd` writes a meta user record, and the resume answers it with a `<synthetic>` `No response requested.` The CLI never streams it (CLI 2.1.319, measured), so only a replay would show it, and `strippingNoResponseFillers` drops it there.
