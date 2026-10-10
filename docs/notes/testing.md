# Testing and CI

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **The probe writes real UserDefaults, `settings.json` and `~/.claude` fixtures; a trap mid-run can leave them dirty.** It runs fine from a Bash tool; silence means the env var did not reach the process.
- **The CI probe job must build Debug** (the probe is `#if DEBUG`; Release launches the app) and ad-hoc signed (no Developer ID in the runner).
- **`connectIfConfigured()` returns silently when `rosterEnabled` is off**, a shared `settings.json` flag read once at launch; no `Roster` log lines means disabled or never fired.
- **Extract CI counts with `awk`, last match.** `sed -n p` multi-line output makes `[ "$n" -lt … ]` exit 2, which `if` reads as false (floor silently passes); first match is forgeable because node's TAP reporter prefixes captured test output with `# `.
- **Node facts:** zero-test file exits 0 as `# pass 1`; `it.skip()` leaves `# pass`; GitHub `run:` is `bash -e` without `pipefail`.
- **Floors equal the current count on purpose.** Raise a floor only after rebasing onto `main`. If a merge conflicts on a floor, build the merged tree and write the measured count (neither side's number is right).
- **Local count below CI means a stale base** (Actions builds the merge ref); diff probe `PASS` names after fetching main.
- **The `test/` file-list check follows node's directory rule (`**/test/**/*.?(c|m)js`)**, only under `test/`, and cannot verify the two non-running lists.
- **Revert one fix at a time when mutation-testing; never use `git checkout -- <path>`** (detached HEAD writes main's copy over the branch; `cp` the file aside). A mutation proves nothing if it does not change behaviour for the fixture.
- **Assertions against a live setting pass vacuously on the dev machine** (bypass-permissions opt-in is ON here). Force the state, restore in `defer`.
- **Fixtures derive constants (`SessionStore.paneAbsoluteCap`); grep the whole fixture for an old value.** Two retyped values stay: `0xFF8000` (`SessionActivity.asking.ledColor`) and `8765` (`MacroPadRemoteEndpoint.defaultPort`).
