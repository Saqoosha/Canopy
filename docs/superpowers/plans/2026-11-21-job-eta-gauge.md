# Job ETA Gauge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the finish time and percent of a long job on the session's sidebar row and on the phone, measured by canopyd from a probe the session's Claude registers, with no model turns.

**Architecture:** A pure estimator (`JobEstimator`) turns probe samples into a `JobSnapshot`. A daemon-side `JobWatcher` runs each registered probe on a timer (locally or over ssh), stores the snapshot on `OpenSession.job`, and posts a push on stall/done. The snapshot rides the existing `session_state` row to the GUI and the roster snapshot to the phone. The GUI draws a progress ring around the existing `ActivityDot` and replaces the elapsed clock with the finish time.

**Tech Stack:** Swift 6 / SwiftUI (Canopy, Xcode 26), Python 3 stdlib (`canopyctl`), TypeScript mod hooks (`canopy-bridge`), Cloudflare Worker + vitest and SwiftUI + XCTest (Canopy-Mobile).

**Spec:** `docs/superpowers/specs/2026-11-21-job-eta-gauge-design.md`

## Global Constraints

- One job per session; registering again replaces it.
- Probe contract: the last `(\d+)\s*/\s*(\d+)` in the output is `done/total`; with `--total N`, the last integer in the output is `done`.
- Defaults: interval 150 s, first run immediately on register, probe timeout 30 s, 3 consecutive failures → `unknown`.
- Rate window: last 15 min, widened until it holds at least 2 points where `done` changed. Fewer than 2 such points → `measuring`, no time.
- Stall: `done` unchanged for `max(15 min, 3 × median time per unit)`, or `--stall-minutes` when given.
- `SessionActivity` is NOT changed. Stall and job colors are a display-level override in the sidebar and on the phone only. Dock badge and MacroPad unchanged.
- Sessions are named with `--session-id "${CLAUDE_SESSION_ID}"` (as `move-session` does). SSH-remote sessions are out of scope.
- ssh: `ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=~/.ssh/cm/%r@%h:%p -o ControlPersist=10m <host> <probe>`, with `SSH_AUTH_SOCK` read from `~/.claude/settings.json` `env.SSH_AUTH_SOCK` on every run (fallback: canopyd's own env). No new key.
- Wire job states: `measuring` / `running` / `stalled` / `unknown` / `done`. `etaAt` is unix seconds or absent.
- Roster now carries `attentionLine` (approved 2026-11-21); the "no conversation content" contract comment and `docs/superpowers/specs/2026-09-03-canopy-mobile-design.md` are rewritten in the same task.
- Push kinds `job_stalled` and `job_done`, each sent once per transition. Worker must accept them (Part B).
- Commits need Saqoosha's go-ahead (CLAUDE.md Restricted Actions). Commit steps below run only after he says so; until then leave changes staged per task.
- Raise `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml` by exactly the number of probe assertions added.

## Review Focus

1. **`done` goes backwards or `total` changes** (job restarted, probe now reads a new log): reset the samples and return to `measuring`, never a negative rate or an ETA in the past. Test in Task 1.
2. **ETA past midnight**: `明日 1:20`, not `1:20`. Test in Task 5 (`JobDisplay.timeLabel`).
3. **ssh blocks on a 1Password approval nobody sees**: the 30 s timeout kills it, counts as a failure, and after 3 the row reads `—` with the hover "ssh の認証に失敗". Never a stall push. Test in Task 3 (failure counting) and Task 3 manual check.
4. **canopyd restarts mid-job**: the registration survives and the next run resumes. Test in Task 3 (persist/restore round trip).
5. **Probe prints nothing numeric** (wrong path, log rotated): counts as a failure, not as `done = 0`. Test in Task 1 (`parse` returns nil).

---

## Part A — Canopy (this worktree)

Build: `xcodegen generate && ./scripts/build_debug_stable.sh`. Probe: `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`. Probe tests are `do { … record("name", condition, detail) }` blocks appended inside `SidebarLogicProbe.runAllTests()` in `Sources/Canopy/_SidebarLogicProbe.swift`.

### Task 1: Probe parsing and the estimator

**Files:**
- Create: `Sources/Canopy/Jobs/JobEstimator.swift`
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Produces:
  - `struct JobSample: Codable, Equatable { let at: Date; let done: Int; let total: Int }`
  - `enum JobState: String, Codable { case measuring, running, stalled, unknown, done }`
  - `struct JobSnapshot: Codable, Equatable { let label: String; let done: Int; let total: Int; let etaAt: Date?; let state: JobState; let stalledSince: Date?; var note: String? }` (`note` is the hover reason Task 3 sets, e.g. "ssh の認証に失敗"; `evaluate` leaves it nil)
  - `enum JobEstimator { static func parse(_ output: String, total: Int?) -> (done: Int, total: Int)?; static func evaluate(label: String, samples: [JobSample], failures: Int, now: Date, stallMinutes: Double?) -> JobSnapshot }`

- [ ] **Step 1: Write the failing probe tests**

```swift
do {
    let p = JobEstimator.parse
    record("job: parse takes the last N/M", p("[12/793] ...\n[328/793] chunk", nil)! == (328, 793))
    record("job: parse with --total takes the last integer", p("1037\n", 1077)! == (1037, 1077))
    record("job: parse with no number is nil", p("No such file\n", nil) == nil && p("", 10) == nil)

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func s(_ min: Double, _ d: Int, _ tot: Int = 793) -> JobSample { JobSample(at: t0.addingTimeInterval(min * 60), done: d, total: tot) }
    let ev = { (ss: [JobSample], nowMin: Double) in
        JobEstimator.evaluate(label: "IG LOD", samples: ss, failures: 0, now: t0.addingTimeInterval(nowMin * 60), stallMinutes: nil) }

    record("job: one sample is measuring", ev([s(0, 100)], 0).state == .measuring && ev([s(0, 100)], 0).etaAt == nil)
    // 8.5 per minute: 465 left → ~54.7 min after the last sample
    let r = ev([s(0, 243), s(5, 285), s(10, 328)], 10)
    record("job: steady rate gives eta from the recent window",
           r.state == .running && abs(r.etaAt!.timeIntervalSince(t0.addingTimeInterval(10 * 60)) - 465 / 8.5 * 60) < 60)
    record("job: done backwards resets to measuring", ev([s(0, 300), s(5, 310), s(10, 20)], 10).state == .measuring)
    record("job: total change resets to measuring", ev([s(0, 300), s(5, 310), s(10, 320, 900)], 10).state == .measuring)
    // one unit per 20 min: window widens, no stall at 16 min without progress
    let slow = ev([s(0, 1, 30), s(20, 2, 30), s(40, 3, 30)], 56)
    record("job: slow units widen the window and do not stall early", slow.state == .running && slow.etaAt != nil)
    // fast job: 15 min floor
    record("job: no progress past the floor is stalled", ev([s(0, 300), s(5, 340), s(10, 380)], 26).state == .stalled)
    record("job: stallMinutes overrides", JobEstimator.evaluate(label: "x", samples: [s(0, 300), s(5, 340), s(10, 380)],
           failures: 0, now: t0.addingTimeInterval(16 * 60), stallMinutes: 5).state == .stalled)
    record("job: 3 failures is unknown", JobEstimator.evaluate(label: "x", samples: [s(0, 1), s(5, 2)], failures: 3,
           now: t0.addingTimeInterval(6 * 60), stallMinutes: nil).state == .unknown)
    record("job: done when done >= total", ev([s(0, 790), s(5, 793)], 5).state == .done)
}
```

- [ ] **Step 2: Build and run the probe; expect compile failure** (`JobEstimator` undefined).

- [ ] **Step 3: Implement `JobEstimator` in `Sources/Canopy/Jobs/JobEstimator.swift`**

`parse`: regex `(\d+)\s*/\s*(\d+)` last match; with `total`, last `\d+`. `evaluate`, in order: failures ≥ 3 → `unknown` (keep last done/total); drop samples before the last point where `done` decreased or `total` changed; done ≥ total → `done`; collect "change points" (samples whose `done` differs from the previous); window = samples in the last 15 min, extended back until it contains ≥ 2 change points; < 2 change points → `measuring`; rate = Δdone/Δt across the window; `etaAt = lastSample.at + (total − done)/rate`; stall threshold = `stallMinutes` or `max(15, 3 × median minutes between change points)`; `now − lastChangePoint.at ≥ threshold` → `stalled` with `stalledSince = lastChangePoint.at` (etaAt nil). Run `xcodegen generate` (new folder).

- [ ] **Step 4: Run the probe; all `job:` records PASS.**

- [ ] **Step 5: Commit** — `git add Sources/Canopy/Jobs project.yml Sources/Canopy/_SidebarLogicProbe.swift && git commit -m "Add the job progress estimator"`

### Task 2: Job on the wire (session_state and roster)

**Files:**
- Modify: `Sources/Canopy/ControlProtocol.swift` (`SessionRow`: add `job: JobSnapshot?`, wire key `"job"` absent while nil)
- Modify: `Sources/Canopy/OpenSession.swift` (add `var job: JobSnapshot?` next to `attentionLine`)
- Modify: `Sources/Canopy/ControlSession.swift` `openRows()` (pass `session.job`)
- Modify: `Sources/Canopy/SessionStore.swift` (~1829, ~1862: copy `row.job` like `backgroundTasks`)
- Modify: `Sources/Canopy/Roster/RosterSnapshot.swift` (`Pane`: add `attentionLine: String?`, `job: JobSnapshot?`, `decodeIfPresent`; rewrite the "Carries no conversation content" doc comment to say it now carries the attention line, dated 2026-11-21)
- Modify: `Sources/Canopy/Roster/RosterPublisher.swift` (~584: fill both)
- Modify: `docs/superpowers/specs/2026-09-03-canopy-mobile-design.md:74` (record the reversal), `docs/CONTROL_PROTOCOL.md` (`job` field)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `JobSnapshot` (Task 1).
- Produces: `JobSnapshot.wire: [String: Any]` with keys `label, done, total, state` and optional `etaAt` (unix seconds, Int) / `stalledSince` / `note`; `JobSnapshot.init?(wire: [String: Any])`. Roster JSON uses the same keys via Codable with `etaAt` encoded as unix seconds (`Int`).

- [ ] **Step 1: Write the failing probe tests**: `"job wire: SessionRow round-trips job"` (row with job → `wire` → `init(wire:)` equal), `"job wire: absent job leaves no key"` (`wire["job"] == nil`), `"roster: pane encodes job and attentionLine with etaAt as Int seconds"` (JSONSerialization of encoded pane has `job.etaAt as? Int == 1_003_300`), `"roster: old pane JSON without the keys decodes"`.
- [ ] **Step 2: Run the probe; expect compile failure.**
- [ ] **Step 3: Implement the fields listed under Files.**
- [ ] **Step 4: Run the probe; PASS.**
- [ ] **Step 5: Commit** — `"Carry job progress and the attention line on the session and roster wire"`

### Task 3: JobWatcher in canopyd, control verbs, canopyctl

**Files:**
- Create: `Sources/Canopy/Jobs/JobWatcher.swift`
- Modify: `Sources/Canopy/ControlSession.swift` (verbs `job_watch`, `job_list`, `job_clear` next to `move_session`; session via `requestedSession`)
- Modify: `Sources/Canopy/CanopyDaemon.swift` (start `JobWatcher.shared` with the daemon's store; restore persisted jobs)
- Modify: `Resources/canopy-bridge/bin/canopyctl` (subcommand `job` with `watch|list|clear`)
- Modify: `docs/CONTROL_PROTOCOL.md`
- Create: `test/canopyctl-job.test.js` (node, spawns `python3 canopyctl` against a fake socket server like `test/helpers.js` patterns) and add it to `CI_TEST_FILES` in `.github/workflows/ci.yml`
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `JobEstimator`, `JobSnapshot`, `OpenSession.job`.
- Produces:
  - `struct JobSpec: Codable, Equatable { let resumeId: String; let label: String; let probe: String; let host: String?; let total: Int?; let interval: TimeInterval; let stallMinutes: Double? }`
  - `@MainActor final class JobWatcher { static let shared; func watch(_ spec: JobSpec); func clear(resumeId: String); func snapshot(resumeId: String) -> JobSnapshot?; static func command(for spec: JobSpec) -> [String]; static func sshAuthSock(settingsJSON: Data?, fallback: String?) -> String? }`
  - Transition callback used by Task 4: `var onTransition: ((OpenSession, JobState, JobSnapshot) -> Void)?`
  - Verb params: `job_watch {sessionId|key, label, probe, host?, total?, interval?, stallMinutes?}` → `{job: JobSnapshot.wire}`; `job_list {sessionId|key}` → `{job: … | null}`; `job_clear {sessionId|key}` → `{cleared: Bool}`.
  - canopyctl: `canopyctl job watch --session-id ID --label L --probe CMD [--host H] [--total N] [--interval S] [--stall-minutes M]`, `canopyctl job list --session-id ID`, `canopyctl job clear --session-id ID`.

- [ ] **Step 1: Write failing probe tests**: `"job: local command is sh -c"` (`command(for:)` == `["/bin/sh","-c",probe]`), `"job: remote command carries BatchMode, ConnectTimeout=10 and ControlPersist"` (array contains each `-o` value and ends with `[host, probe]`), `"job: SSH_AUTH_SOCK comes from settings.json env"` (`sshAuthSock(settingsJSON: #"{"env":{"SSH_AUTH_SOCK":"/x/agent.sock"}}"#…, fallback: "/y")` == `"/x/agent.sock"`; nil JSON → `"/y"`), `"job: specs persist and restore"` (encode `[JobSpec]` → decode equal), `"job: a failed run increments failures and a parsed run resets them"`.
- [ ] **Step 2: Write the failing node test** `test/canopyctl-job.test.js`: `job watch` sends `{"verb":"job_watch","params":{"sessionId":"S","label":"L","probe":"P","host":"rt4090","interval":150}}` (assert the JSON the fake server receives), `job list` sends `job_list`, missing `--probe` exits non-zero.
- [ ] **Step 3: Run both; expect failures.**
- [ ] **Step 4: Implement.** One `Timer` per job on the main actor; each tick runs `Process` with `command(for:)`, env `SSH_AUTH_SOCK` from `sshAuthSock` reading `~/.claude/settings.json`, `ssh` needs `~/.ssh/cm` to exist (create it 0700); terminate at 30 s. Append a `JobSample` on a parsed result (keep the last 4 h), else increment `failures`. Set `session.job = JobEstimator.evaluate(...)`; call `onTransition` when `state` changes. Persist `[JobSpec]` to `~/Library/Application Support/Canopy/jobs-<bundle id>.json` on every change; restore on daemon start, dropping specs whose session is not open. Clear the job when its session closes. When `--host` is set and the probe fails with ssh exit 255, set the snapshot's `note` to "ssh の認証に失敗".
- [ ] **Step 5: Run probe and `node --test test/canopyctl-job.test.js`; PASS.**
- [ ] **Step 6: Manual check (Review Focus 3):** in a Canopy session, `canopyctl job watch --session-id "$CLAUDE_SESSION_ID" --label t --host rt4090 --probe 'echo 3/10'`, then `canopyctl job list …` shows `measuring` with done 3; lock 1Password and confirm the row later reads `unknown` with the note and no push.
- [ ] **Step 7: Raise `EXPECTED_ASSERTIONS`; commit** — `"Run registered job probes in canopyd and expose job verbs"`

### Task 4: Pushes on stall and done

**Files:**
- Modify: `Sources/Canopy/Roster/RosterNotifier.swift` (`Kind`: add `jobStalled = "job_stalled"`, `jobDone = "job_done"`)
- Modify: `Sources/Canopy/Jobs/JobWatcher.swift` (wire `onTransition` → `RosterNotifier.post`)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `JobWatcher.onTransition` (Task 3), `RosterNotifier.post(kind:sessionId:resumeId:title:body:...)`.
- Produces: `static func JobWatcher.pushText(_ job: JobSnapshot) -> (title: String, body: String)?` — `stalled` → (`label`, `"\(done)/\(total) で止まっている"`), `done` → (`label`, `"完了"`), every other state → nil.

- [ ] **Step 1: Failing probe tests**: `"job push: stalled text"`, `"job push: done text"`, `"job push: running sends nothing"`, `"job push: one push per transition"` (feed `running→stalled→stalled→running→stalled`, count posts via an injected closure = 2).
- [ ] **Step 2: Run; fail. Step 3: Implement (post with `answerable: false`, `sessionTitle: session.title`). Step 4: Run; PASS. Step 5: Raise count; commit** — `"Push once when a job stalls or finishes"`

### Task 5: Sidebar ring, finish time and unread on done

**Files:**
- Create: `Sources/Canopy/Jobs/JobDisplay.swift`
- Modify: `Sources/Canopy/Sidebar.swift` (`SidebarRowView.iconView`, `trailingStatus`, help text; `ProgressRing` view)
- Modify: `Sources/Canopy/SidebarRow.swift` (`SidebarStatusGroup.sections`: a stalled job puts the row in `.needsYou`; `showsAttentionLine` also true when stalled)
- Modify: `Sources/Canopy/MacroPad/MacroPadController.swift` (`MacroPadUnreadTracker.Snapshot` gains `jobDone: Bool`; a false→true edge marks unread like `isThinking` true→false; ~981 passes `$0.job?.state == .done`)
- Test: `Sources/Canopy/_SidebarLogicProbe.swift`

**Interfaces:**
- Consumes: `OpenSession.job`, `SessionActivity`, `SessionActivity.dotRGB`.
- Produces:
  - `enum JobDisplay { static func ringActivity(_ activity: SessionActivity, job: JobSnapshot?) -> SessionActivity; static func timeLabel(_ eta: Date, now: Date, calendar: Calendar) -> String; static func trailing(_ job: JobSnapshot, now: Date) -> (top: String, bottom: String?, isAlert: Bool); static func help(_ job: JobSnapshot, now: Date) -> String; static func stalledLine(_ job: JobSnapshot) -> String }`
  - `ringActivity`: job nil → `activity`; `asking`/`error` stay; stalled → `.error` (color only, never written back to the session); `idle`/`unread` with a running/measuring/unknown job → `.background`; else `activity`.

- [ ] **Step 1: Failing probe tests** with exact values:
  - `timeLabel(10:40 same day)` == `"10:40"`; `timeLabel(01:20 next day)` == `"明日 1:20"`
  - `trailing(running 328/793 eta 10:40)` == (`"10:40"`, `"41%"`, false); `trailing(stalled since 15 min)` == (`"停止"`, `"15m"`, true); `trailing(measuring)` == (`"計測中"`, `"41%"`, false); `trailing(unknown)` == (`"—"`, nil, false)
  - `help(running …)` == `"IG LOD 328/793 · あと 55 分"`; unknown with note → `"IG LOD · ssh の認証に失敗"`
  - `stalledLine` == `"680/1077 で止まっている"`
  - `ringActivity(.idle, running)` == `.background`; `(.asking, stalled)` == `.asking`; `(.working, stalled)` == `.error`; `(.idle, nil)` == `.idle`
  - sections: an idle session with a stalled job lands in Needs you
  - unread tracker: `jobDone` false→true marks unread; true→true does not
- [ ] **Step 2: Run; fail.**
- [ ] **Step 3: Implement.** `ProgressRing`: 18 pt frame, 2 pt stroke, track at 18% opacity, arc from 12 o'clock clockwise by `done/total`, both in `ringActivity(...).dotRGB`; the existing `ActivityDot` drawn inside, colored by `ringActivity` (breath unchanged). `trailingStatus`: when `session.job` is non-nil, show `top` (semibold, red when `isAlert`) over `bottom` instead of the elapsed clock; the `bg: N` chip stays. The row's attention line shows `stalledLine` while stalled.
- [ ] **Step 4: Run probe; PASS. Step 5: Visual check** in the Debug build with `canopyctl job watch … --probe 'echo $(( $(date +%s) / 10 % 100 ))/100'` (moves every 10 s): ring grows, time shows, then stop the counter with `--probe 'echo 5/100'` and `--stall-minutes 1` to see the red ring move to Needs you.
- [ ] **Step 6: Raise count; commit** — `"Draw job progress rings and finish times in the sidebar"`

### Task 6: Teach Claude (bridge skill and hook nudge)

**Files:**
- Create: `Resources/canopy-bridge/skills/job-watch/SKILL.md`
- Modify: `Sources/Canopy/ShimProcess.swift` (`bridgeModFiles` += `"skills/job-watch/SKILL.md"`)
- Modify: `Resources/canopy-bridge/hooks/register.ts` (new `on('tool.call', { tool: 'Bash' }, …)`)
- Create: `Resources/canopy-bridge/hooks/job-nudge.test.ts`

**Interfaces:**
- Consumes: `canopyctl job …` (Task 3).
- Produces: `export const LONG_JOB = /\bnohup\b|\bsetsid\b|\btmux\s+new(-session)?\b[^|;]*\s-d\b|\bscreen\s+-d?m|\bssh\b[^|;]*&\s*$/m` and `export const JOB_NUDGE` (the one-line note text below).

SKILL.md frontmatter: `name: job-watch`, description: "Register a long-running job (training, rendering, encoding, batch processing; anything over about 10 minutes) so Canopy shows its finish time on the sidebar and the phone. Use right after starting such a job, and when the user asks for an ETA or how long something will take." Body: the three `canopyctl job` commands with `--session-id "${CLAUDE_SESSION_ID}"`; probe examples (`grep -oE "\[[0-9]+/793\]" log | tail -1`; `ls renders/h7_final | grep -c png` with `--total 1077`; `--host rt4090` for remote); "on an ETA question run `canopyctl job list` and answer from it, no ssh"; "not available in SSH-remote sessions".

JOB_NUDGE: `"This looks like a long-running job. If it reports progress as N/M (or a count with a known total), register it with the job-watch skill so Canopy shows its finish time."`

- [ ] **Step 1: Failing hook test** (`claude-code/testing`, engine shaped like `slack-gate.test.ts`): a Bash call `nohup python train.py > log 2>&1 &` with no job registered returns a result whose model-visible text ends with `JOB_NUDGE`; `run_in_background: true` likewise; `ls -la` gets no note; a second long job within 30 min gets no note (store key `job-nudge:<session id>` holds the last time); when `process.run` of `canopyctl job list` reports a job, no note.
- [ ] **Step 2: Run `scripts/test_canopy_bridge.sh`; fail.**
- [ ] **Step 3: Implement.** After `next(e)`, append the note to the result's model-visible text. Confirm which result field the model sees from the mod type definitions written by `claude plugin test` (`.claude-plugin/types/` in the temp copy); if `text` is not it, use the field those types name for tool output.
- [ ] **Step 4: Run; PASS. Probe's "every bundled skill file is listed" passes.**
- [ ] **Step 5: Commit** — `"Teach sessions to register long jobs"`

## Part B — Canopy-Mobile (clone `Saqoosha/Canopy-Mobile` into a worktree branch `job-eta-gauge`)

### Task 7: Worker accepts job pushes and types the new fields

**Files:**
- Modify: `worker/src/types.ts` (`PaneRow`: `attentionLine?: string; job?: { label: string; done: number; total: number; etaAt?: number; state: "measuring"|"running"|"stalled"|"unknown"|"done"; note?: string }`; `NotifyBody.kind` adds `"job_stalled" | "job_done"`)
- Modify: `worker/src/index.ts` (`/notify`: accept the two kinds under the same rules as `completed`: no `requestId`)
- Test: `worker/src/index.test.ts`

- [ ] **Step 1: Failing vitest cases**: `/notify` with `kind: "job_stalled"` and no requestId → 200; with a requestId → 400; unknown kind still 400 with the updated message `"kind must be completed, asking, job_stalled or job_done"`.
- [ ] **Step 2: `cd worker && npm test`; fail. Step 3: Implement. Step 4: PASS.**
- [ ] **Step 5: Commit; deploy only with Saqoosha's go-ahead** (`npm run deploy`). Until deployed, Mac job pushes get 400 and are dropped (fire-and-forget); nothing else breaks.

### Task 8: Phone rows show the ring, time and attention line

**Files:**
- Modify: `Sources/RosterModels.swift` (`PaneRow`: `let attentionLine: String?`, `let job: PaneJob?`; `struct PaneJob: Codable, Equatable { let label: String; let done: Int; let total: Int; let etaAt: Int?; let state: String; let note: String? }`)
- Create: `Sources/JobDisplay.swift` (same functions and strings as Canopy's `JobDisplay`, taking `PaneJob` and the pane's `state` string)
- Modify: `Sources/RosterView.swift` `paneRow` (ring around the `Circle`, trailing `top/bottom` instead of elapsed when `job != nil`, caption line shows `attentionLine` when state is asking/unread or the job is stalled; a stalled job also counts in `attentionPanes`)
- Test: `Tests/JobDisplayTests.swift`, `Tests/RosterModelsTests.swift` (or the existing decoding test file)

- [ ] **Step 1: Failing XCTests**: decoding a pane JSON with `job` and `attentionLine`; decoding one without them; `JobDisplay` cases copied from Task 5 Step 1 with the same expected strings (including `"明日 1:20"`, `"停止"`, `"計測中"`).
- [ ] **Step 2: Run the app tests (`xcodebuild test` per the repo's AGENTS.md); fail. Step 3: Implement. Step 4: PASS.**
- [ ] **Step 5: Visual check** on the simulator against a Mac publishing a job (Task 5 Step 5 probe). **Step 6: Commit.**

---

## Self-review notes

- Spec coverage: registration (T3), measurement/stall/unknown/done (T1, T3), row state override (T5), sidebar look (T5), unread on done (T5), phone fields and look (T2, T8), roster contract reversal (T2), pushes (T4, T7), skill and hook (T6), SSH-remote exclusion (T6 skill text). MacroPad and auto-detection stay out.
