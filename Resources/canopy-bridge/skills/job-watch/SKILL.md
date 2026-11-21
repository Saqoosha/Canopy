---
name: job-watch
description: Register a long-running job (training, rendering, encoding, batch processing; anything over about 10 minutes) so Canopy shows its finish time on the sidebar and the phone. Use right after starting such a job, and when the user asks for an ETA or how long something will take.
---

# Show a long job's finish time in Canopy

Canopy runs a probe you give it every few minutes, without you, and shows the job's progress as a ring on this session's sidebar row, with the finish time on the right. The phone shows the same. If the count stops moving, the row turns red, moves to Needs you, and the phone gets one push. When it reaches the total, the phone gets one push.

## Register right after starting the job

```bash
canopyctl job watch --session-id "${CLAUDE_SESSION_ID}" --label "IG LOD" \
  --probe 'grep -oE "\[[0-9]+/793\]" ~/woven-city/logs/ig_lod.log | tail -1' --host rt4090
```

- `--probe`: a shell command whose output ends with `N/M` (done/total). Canopy reads the last `N/M` it prints.
- `--total N`: when the probe can only print a count, e.g. `--probe 'ls renders/h7_final | wc -l' --total 1077`. Use `wc -l`, not `grep -c`: `grep -c` exits 1 at a count of 0, and a probe that exits non-zero counts as a failed reading.
- `--host`: run the probe over ssh on that host (as `ssh <host> '<probe>'`). Omit it for a job on this Mac.
- `--label`: a short name, shown on hover and in the push.
- `--interval` (seconds, default 150) and `--stall-minutes` (default: 60 until the count has moved twice, then the larger of 15 and three times the usual time per step). Pass `--stall-minutes` when one step can take longer than that, such as one epoch of a slow training run.

Check the probe once by hand before registering: it must exit 0, print the count, and print nothing after it that ends in a different `N/M`. One job per session; registering again replaces it.

## When asked for an ETA

Do not ssh to look. Read what Canopy already measured:

```bash
canopyctl job list --session-id "${CLAUDE_SESSION_ID}"
```

`etaAt` is the finish time in unix seconds; answer with the local time. `state` is `measuring` (not enough readings yet), `running`, `stalled`, `unknown` (the probe keeps failing; `note` says why) or `done`. If the job has later steps that are not counted (encoding after a render), add their time yourself.

## When the job is over or replaced

```bash
canopyctl job clear --session-id "${CLAUDE_SESSION_ID}"
```

A finished job clears its ring by itself; clear it when you abandon a job.

## Limits

- Not available in an SSH-remote session (Canopy's session over ssh): there is no control socket there.
- A local probe runs under canopyd's `PATH` plus `/opt/homebrew/bin` and `/usr/local/bin`, not your login shell's: name any other tool by its full path. Over ssh it runs in the remote login's shell and uses the same SSH agent as this session.
- After three failed readings the job shows `—` and Canopy retries only every 15 minutes.
