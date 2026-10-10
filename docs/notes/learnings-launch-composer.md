# Learnings: Launch composer

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Do not re-add recent-folder or session-history lists to the launcher** — the sidebar already lists them.
- **Put chip styling on the `Menu` (`.chipStyle()`), not its `label:`** — the AppKit cell silently drops background, border and extra images; leave `.menuIndicator` visible.
- **Chips wrap (`ChipFlowLayout`), never scroll** — a ScrollView slices the last chip in narrow multi-pane launchers.
- **The branch chip must use `ShimProcess.detectVCSInfo`** — repos are jj-colocated, so a git-only read shows `detached`.
- **Centre with `composerCenteringInset`, not `.defaultScrollAnchor(.center)`** — a half-point offset makes every control unclickable. Click harnesses need whole-point coordinates.
- **After deleting a view, audit `@State` flags against surviving `.sheet(` presenters** — a build catches orphaned triggers (e.g. choosing a saved SSH host but no way to add one).
