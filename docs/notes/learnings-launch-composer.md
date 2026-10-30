# Learnings: Launch composer

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Do not re-add recent-folder or session-history lists to the launcher** — the sidebar already lists them.
- **Menu chips use `chipMenu()` (plain-button menu style), not `.borderlessButton`** — that style hands the label to an AppKit cell that drops background, border and extra images and repaints it in the primary color, so `ChipLabel(muted:)` never showed. `ChipLabel` draws the pill and chevron itself when it labels a menu.
- **Menu rows that mark a choice use `CheckItem` (a `Toggle`)** — `Label(_, systemImage: "checkmark")` in a menu draws no image.
- **Chips wrap (`ChipFlowLayout`), never scroll** — a ScrollView slices the last chip in narrow multi-pane launchers.
- **The branch chip must use `ShimProcess.detectVCSInfo`** — repos are jj-colocated, so a git-only read shows `detached`.
- **Centre with `composerCenteringInset`, not `.defaultScrollAnchor(.center)`** — a half-point offset makes every control unclickable. Click harnesses need whole-point coordinates.
- **After deleting a view, audit `@State` flags against surviving `.sheet(` presenters** — a build catches orphaned triggers (e.g. choosing a saved SSH host but no way to add one).
