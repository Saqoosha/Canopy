# Webview, protocol and CLI bridge

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Load the entry page with `loadFileURL`, never `loadHTMLString`** — local file access needs it.
- **One entry file per session (`_canopy-<OpenSession.id>.html`), keyed by session UUID, never shared** — `data-initial-session` is baked in and loads are async, so a shared file renders the wrong conversation; it must outlive the load because `reload()` re-reads it.
- **Entry files live in `webview-entries/<pid>-<uuid>/`; the writer flock-holds `<pid>-<uuid>.lock` beside it until it exits, and makes the lock first** — the folder is shared with the other build, so only the owner's quit purge, or a launch sweep that can take the lock or finds none, deletes a directory.
- **CLI flags: `-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages`**; events pass to the webview as `io_message` unconverted, but the content array must become a plain string before CLI stdin.
- **Mirror `compress: "br"`: the server must refuse `Z` input** — pre-auth decompression bomb.
- **Mirror replays are fitted under `mirrorReplayMaxBytes`; both line buffers cut the connection at 16 MiB.**
- **Mirror `usage` and `images` are Mac-client-only; every option is opt-in so older clients are unaffected.**
- **Mirror resume (`since` + `channelId`) must not be used by a page with requests in flight** — their owners died with the old connection.
