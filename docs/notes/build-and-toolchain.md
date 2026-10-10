# Build and toolchain

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **`SWIFT_STRICT_CONCURRENCY: complete` in `project.yml` is a sibling of `configs:` and XcodeGen discards it.** Moving it under `base:` adds 35 warnings (issue #143); not a fix to make in passing.
- **Only Xcode 16.4 (fails) and 26.6 (passes) have been built.** `macos-26` is the CI image; `macos-15`'s Xcode 26.0–26.3 is untried.
- **The Sparkle floor (2.9.2) does not move when the pin is bumped.** Bump by editing `project.yml` only; `sparkle-watch.yml` reports newer upstream releases.
- **Alternating `build_debug_stable.sh` (Apple Development) with `scripts/build.sh`, `auto-adopt.sh` or Cmd+R (Developer ID) re-prompts TCC each switch** (issue #141). Why the script overrides the identity is unrecorded; do not invent a reason.
- **`CanopyMain` picks the role before `NSApplication` exists** (`--daemon`, `--unregister-daemon`, else the app with `OpenSession.localSessionsRunInDaemon = true`, except under the logic probe).
