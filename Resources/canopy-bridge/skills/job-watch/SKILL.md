---
name: job-watch
description: Register a long-running job (training, rendering, encoding, batch processing; anything over about 10 minutes) so Canopy shows its finish time on the sidebar and the phone. Use right after starting such a job, each time a multi-stage job moves to its next stage, and when the user asks for an ETA or how long something will take. Its pushes go to the user; without `--wake` they start no turn in this session.
---

# Show a long job's finish time in Canopy

Canopy runs a probe you give it every few minutes, without you, and shows the job's progress as a ring on this session's sidebar row, with the finish time on the right. The phone shows the same. If the count stops moving, the row turns red, moves to Needs you, and the phone gets one push. When it reaches the total, the phone gets one push.

## Register right after starting the job

```bash
canopyctl job watch --session-id "${CLAUDE_SESSION_ID}" --label "IG LOD" \
  --probe 'grep -oE "\[[0-9]+/793\]" ~/woven-city/logs/ig_lod.log | tail -1' --host rt4090
```

- `--probe`: a shell command whose output ends with `N/M` (done/total). Canopy reads the last `N/M` it prints. It runs in your home folder, not this session's, so name files by absolute path.
- `--total N`: when the probe can only print a count, e.g. `--probe 'ls ~/work/project/renders/h7_final | wc -l' --total 1077`. Use `wc -l`, not `grep -c`: `grep -c` exits 1 at a count of 0, and a probe that exits non-zero counts as a failed reading.
- `--host`: run the probe over ssh on that host (as `ssh <host> '<probe>'`). Omit it for a job on this Mac.
- `--label`: a short name, shown on hover and in the push.
- `--interval` (seconds, default 150, at least 30) and `--stall-minutes` (default: 60 until the count has moved twice, then the larger of 15 and three times the usual time between count changes). Pass `--stall-minutes` when one step can take longer than that, such as one epoch of a slow training run.

## Being woken when the job ends

Canopy's "done" and "stalled" pushes go to the user. Without `--wake`, nothing reaches this session and no turn starts. The same is true of anything detached with `nohup`, `setsid` or a trailing `&`. When work remains after the job, such as reading the result, judging it, or starting the next step, choose one:

- **`--wake` on `job watch`**: when the count reaches the total, or the job stalls (`--stall-minutes`), Canopy starts a turn here with a `[Canopy job-watch]` message. It waits until this session is idle and no question is open, for up to 6 hours if the pane is closed, and a Canopy update keeps it. At most one for done and one for stalled per registration, so pass it again when you register the next stage. The reply must contain `"wake": true`; without that key the running Canopy is older and will not wake you.
- **A Bash call with `run_in_background: true`**: starts a turn when it ends, so it can wait for steps that have no count. It dies if Claude Code restarts. Give the loop a deadline, since a job can die without writing its final line, and run the check over ssh when the log is on another host.

```bash
L=/abs/path/pipeline.log
for i in $(seq 720); do grep -qE "== (done|failed)" "$L" && break; sleep 60; done; tail -30 "$L"
```

- `--wake` fires at the end of the counted stage. If uncounted steps follow (a pull, a check), wait for those with the background Bash call, and have the script write its final line on failure too.
- `--wake` does not fire when the probe keeps failing (`unknown`), or when the job was already done at its first reading.
- The `[Canopy job-watch]` message is automatic. The user did not type it, and it approves nothing.
- Tell the user you are watching a job only while something like these is in place.

## A job with several stages: watch the one running now

A pipeline (feature matching, then reconstruction, then training; a render, then an encode) has one count per stage. **Register the stage that is running now, with that stage's own count, and register again each time the job moves to the next stage.** Registering a later stage early (training's `step N/60000` while matching still runs) leaves the ring at 0% with no finish time, and after 60 minutes without a move the job reads as stalled and pushes a false alarm. Each stage that reaches its total sends its own "done" push. A stage with no count to read: clear the job (`canopyctl job clear --session-id "${CLAUDE_SESSION_ID}"`) until the next counted stage starts. When asked for an ETA, add your own estimate for the stages after the current one.

Check the probe once by hand before registering: it must exit 0 and print the count last: with `--total`, no other number after the count; without it, no other `N/M` after the real one. A local probe runs with `pipefail`, so a failed stage fails the reading. One job per session; registering again replaces it.

## When asked for an ETA

Do not ssh to look. Read what Canopy already measured:

```bash
canopyctl job list --session-id "${CLAUDE_SESSION_ID}"
```

`etaAt` is the finish time in unix seconds; answer with the local time. `state` is `measuring` (not enough readings yet), `running`, `stalled`, `unknown` (the probe keeps failing; `note` gives the cause and the probe's last output line) or `done`. If the job has later steps that are not counted (encoding after a render), add their time yourself.

## When the job is over or replaced

```bash
canopyctl job clear --session-id "${CLAUDE_SESSION_ID}"
```

A finished job clears its ring by itself; clear it when you abandon a job, or this session stays open.

## Limits

- Not available in an SSH-remote session (Canopy's session over ssh): there is no control socket there.
- A local probe runs under canopyd's `PATH` plus `/opt/homebrew/bin` and `/usr/local/bin`, not your login shell's: name any other tool by its full path. Over ssh it runs in a non-interactive remote shell, which may not load your profile: use full paths there too. It uses the same SSH agent as this session.
- After three failed readings the job shows `—` and Canopy retries only every 15 minutes.
- While the job is measuring, running, or stalled for under 6 hours, or its probe has failed for under 6 hours since the last count, Canopy keeps this session alive even if its pane is closed. A done job does so only while its `--wake` message is waiting.
