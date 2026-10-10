# Release

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Run `scripts/wait_for_appcast.sh <ver>` to confirm a release reached users**; gh-pages pushes have silently failed to build twice.
- **Verify a fresh appcast against `origin/gh-pages`, never the Pages URL** (it serves the old release for a while and looks like failure).
- **The appcast must sign the exact DMG published** (issue #188). A mismatch makes Sparkle silently discard the item. Keep `update_appcast.sh` failing before gh-pages unless the downloaded asset is `cmp`-identical to the signed file AND the appcast `length` equals its size; the xattr strip predicate must stay `com.apple.cs.*`.
- **Fixing the cause repairs nothing already published**; run `scripts/repair_appcast.sh` (audits; `--push` fixes).
- **Env-assignment prefixes scope to one command**: `VAR=x cmd1 | cmd2` does not give `cmd2` the variable. Pass values as `argv`.
- **Keep the `codesign` capture in `codesign_retry.sh` inside an `if` condition**, or `set -e` exits before the retry runs; test under `-e`.
- **Notarize from `/tmp` workdirs** (Time Machine can hang `notarytool` on `~/Documents`); a running backup alone is not a reason to postpone.
- **Never `hdiutil detach` while `notarytool` runs.** Leaked DMG mounts are why the next release hangs; `scripts/detach_dmg_mounts.sh` handles them.
- **Hung `notarytool submit` recovery, in order:** (1) `notarytool history` confirms nothing reached Apple; (2) kill the `notarytool` PID; (3) let the script's EXIT trap run; (4) if the image is still attached, run `scripts/detach_dmg_mounts.sh <dirs>` (it kills the helper bound by `hdiutil info -plist`'s `hdid-pid`; `lsof` names nobody); (5) re-run the release (only the `project.yml` bump happened).
