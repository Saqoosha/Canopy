# Feature notes

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`. Feature overview: README.md.

- **MacroPad firmware lives in <https://github.com/Saqoosha/Canopy-MacroPad>** (primary for protocol and colours; no tags or releases). A Canopy change citing firmware behaviour lands after the firmware merge to `main`.
- **The MacroPad controller runs with no pad plugged in** (it owns the unread state the sidebar dot reads). Manual sleep (issue #147) is the two outermost keys held for `MacroPadSleepChord.holdDuration`; both presses act as normal presses, and nothing on screen shows sleep.
- **Mac-to-Mac uses the other Mac's daemon; SSH remote is for hosts that cannot run it** (Linux, WSL, Windows).
- **`docs/architecture.html` is published from `gh-pages`**; update both copies.
