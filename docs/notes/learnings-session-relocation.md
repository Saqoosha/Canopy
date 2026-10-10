# Learnings: Session relocation

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Nothing on the stream-json wire reports a relocation** (`EnterWorktree`/`ExitWorktree`); `system/init` is not re-emitted. Only the JSONL shows it: `{"type":"relocated","relocatedCwd":…}` and the file having moved.
- **The transcript moves to the new directory's project folder, so lookups keyed on the spawn directory miss silently** (`sessionFileExists`, `ShimProcess.jsonlPath`, `loadUserPrompts`, `countMessages`). Fall back to `ClaudeSessionHistory.scanForTranscript(sessionId:)` only after the encoded-path stat, and do not stop at the first hit.
- **Compare paths after resolving symlinks** — `~/Documents/repos` and `~/repos` both exist as project folders.
- **The two relocated-directory `detectVCSInfo` calls in `ShimProcess` are unpinned by any probe.** Verify by planting a launch-restore snapshot (`defaults write sh.saqoo.Canopy.debug canopy.sessionRestore.v1 -data …`) and screenshotting the Debug build.
