# Learnings: Phone reply queue

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Queue only gates that clear on their own; refuse (409) a dead shim, a pending permission request, or a waiting AskUserQuestion** (`ShimProcess.blockingReasonForReply()`). The phone reads only the status code, so a queued prompt behind a human gate is lost silently.
- **Liveness is `process?.isRunning == true && !isIntentionalStop`.** On a dead shim `isWorking` and `channelId` stay latched (`resetActivityState` clears neither), so replies would queue, return `ok`, and vanish with no log line.
- **Keep one spelling of the gate** between `requestPhoneReply` and `ineligibilityReasonForReply()`; a divergence makes the drain's drop branch reachable and the dropped text is never logged.
- **Drain by the 0.5 s poll, not hooks on the gates** — gates clear from too many places to enumerate. One injection per tick via `phoneReplyInFlight`.
- **A queued prompt returns `ok: true`** (`DeliveryOutcome.queued`); a 409 makes the phone hand the text back and invites a duplicate send.
- **Discard the queue from three places:** `resetActivityState`, `stop()` (before its early return, since `stop()` blocks main while killing the tree and a due tick would write to a closed pipe), and `discardAllQueuedPhoneReplies()` from `applicationWillTerminate` (which never calls `stop()`).
- **No probe covers the tick, serialisation, teardown discard, or the inputs to `blockingReasonForReply()`.** Check on a Debug build with a phone: log shows `queued at depth N`, then `injected` one tick later.
