# SSH remote

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Pass the wrapper path only via `CANOPY_SSH_WRAPPER_PATH` (per-shim override)** — writing it to the shared settings file leaks across sessions and breaks `/resume`.
- **"Continue session" needs both `RemoteSessionHistory` (picks the session over SSH) and `CANOPY_REMOTE_RESUME` (wrapper passes `--resume`)** — either alone silently starts a fresh conversation; reconnect (`doReconnect`) must pass the resume id too.
- **Send a resume id only if it names a real transcript** — the CLI exits 1 on an unresolvable `--resume`, and new sessions carry a placeholder id.
- **Keep `CLAUDE_CODE_ENTRYPOINT` in the wrapper's forwarded env** — otherwise remote transcripts are stamped `sdk-cli` and hidden as automated.
- **A resumed remote pane shows an empty chat over a model with full context** — the extension reads the JSONL locally.
- **Wrap remote commands in `/bin/sh -c`** — the remote login shell may be fish.
- **Known gap:** SSH death leaves the Node shim alive, so `terminationHandler` does not fire and no reconnect overlay appears; detect CLI exit via shim stderr or an extension message.
- **Known gap:** `@`-mention listing and `open_file` do not work remotely (workspace.fs is local); only non-Mac hosts need this, since Mac hosts run canopyd.
