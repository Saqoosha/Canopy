# Canopy Mobile — notification history and detail

**Date:** 2026-09-04
**Status:** design agreed, not implemented
**Supersedes nothing.** Extends `2026-09-03-canopy-mobile-design.md` (steps 4-5, shipped).

## The problem, in the form it was reported

> "I need it when I'm typing a reply."

The reply sheet shows a session title and nothing else. You are asked to say what to do next about a session whose last words you cannot see. That is not replying; it is guessing.

A second, sharper case: a notification that arrives while the phone is locked and is never tapped leaves **no record at all**. The roster row survives, but what actually finished does not. On the overnight shape this app is for — several sessions finishing while you are away — that is most of the value missing.

## Scope

**In:** the completion notification carries the assistant's final message; the phone keeps a history of received notifications and renders one in detail; a reply can be composed from that detail.

**Also in:** permission requests become answerable from the phone, with Allow and Deny — see below for why that could not be left out.

**Out:** reading a transcript. Starting or closing sessions. Waking a session that has no live shim.

## What was measured, not assumed

- **The final assistant text is already on the wire.** A `result` frame carries `"result": "<final text>"` — captured 2026-09-04 from `claude -p --output-format stream-json --verbose`. `postTaskCompletedNotification()` is called from that same `result` branch, so the text is in hand at exactly the moment the notification is composed. **No accumulation, no JSONL re-read, no race.** `ShimProcess` gains no new state.
- **Canopy holds no assistant text today.** It tracks `lastAssistantHadAskUserQuestion`, a `Bool`, and nothing else. Anything that needed the message body before this change would have had to build it.
- **Pager's history is four pieces**: `NotificationHistoryItem` (Codable, with `body` and an optional LLM-shortened `bodyShort`), `HistoryStore` (one file per item in an App Group container, `maxItems = 100`), `HistoryUpdateBridge`, and a Notification Service Extension whose `didReceive` reads custom keys out of `userInfo`, appends the item, and then mutates the banner.
- **The Notification Service Extension is the only way to capture an untapped notification.** A push that is never tapped never reaches the app; the NSE runs for every delivered push.
- **`shortenWithLLM` calls `claude-haiku-4-5` at `api.anthropic.com` with `ANTHROPIC_API_KEY`**, behind an `AbortController` timeout.

## Why this does not reverse the roster's content rule

The shipped spec says the roster carries no conversation content, and that stands. It also already says, in the same document:

> The notification path is a separate matter and **does carry content**.

So the boundary being crossed here was drawn deliberately on the other side. Nothing about `RosterSnapshot` changes.

## Permission requests move to Canopy Mobile

An earlier draft of this design left them with Pager, on the grounds that Pager's flow already works and answers from the Apple Watch. That was wrong, and the reason is not about capability — it is about what a notification promises.

**A `.asking` push that can only be looked at is worse than no push at all.** Today Canopy Mobile sends one, you tap it, the reply sheet opens, you type — and the reply is refused, because `requestPhoneReply` declines while `pendingPermissionRequestIds` is non-empty. That is precisely the state the notification announced. You now believe you answered; the session is still blocked; nothing on either device says so. **The session stays stuck for as long as you are away**, which is exactly the window this app exists to cover.

So the notification must carry a real answer path, or it must not exist. It gets one.

**The injection path is measured, not assumed.** `tool_permission_response` is a webview→extension message (found in the extension bundle at 2.1.90), and `ShimProcess` already synthesizes webview messages for the keep-alive and for phone replies. The decision travels the same road as a reply; only the envelope differs.

**Consequences:**
- The push for `kind: "asking"` carries the tool name and the request's own text, and its notification category offers **Allow** and **Deny** as actions — answerable from the lock screen and the Watch, the way Pager's is.
- A decision is **not** a user turn. It must not go through `requestPhoneReply`, must not touch the busy-shim guard, and must not appear in the transcript as typed text. It is a response to an outstanding request id.
- `permission-request.sh` in Pager now **does** stand down for Canopy-hosted claude sessions, because Canopy genuinely replaces the capability. That reverses the ruling made during the previous build — correctly, since that ruling's stated condition was "Canopy does not replace this", and now it does.
- **The request id is the correlation key**, and it is per-process like a session id. A decision arriving for an id no longer outstanding must be dropped and logged, never applied to whatever is outstanding now.

## The shape

```
ShimProcess (result frame)
  → RosterNotifier.post(kind:.completed, body: <final assistant text>)
      → relay POST /notify  { …, bodyFull }
          → shortenWithLLM when long  → banner
          → APNs payload: banner + bodyFull as a custom key
              → NSE didReceive: append to HistoryStore, then show the banner
                  → app: history list → detail → reply sheet, prefilled context
```

**`bodyFull` rides in the push payload, not in KV.** Two reasons: the relay must not accumulate conversation text keyed by device, and the NSE has no credential to fetch it with. The 3000-character cap already in `/notify` is what keeps the payload under the APNs 4 KB limit; it now applies to `bodyFull`.

## What each repo gains

**Canopy** — one field. `postTaskCompletedNotification()` passes the `result` frame's text through to `RosterNotifier.post`. The local macOS banner is unchanged.

**Canopy-Mobile relay** — `NotifyBody` gains `bodyFull`; `shortenWithLLM` and its `ANTHROPIC_API_KEY` binding are copied from Pager, for the same reason `apns.ts` was copied: the two Workers diverge by design while the credential is genuinely shared. **A new secret is required.**

**Canopy-Mobile app** — a Notification Service Extension target, the App Group `group.sh.saqoo.canopy-app` on both targets, and `NotificationHistoryItem` / `HistoryStore` / `HistoryUpdateBridge` copied from Pager. A history list, a detail view, and a reply sheet reachable from the detail.

**Pager** — one line. `permission-request.sh` gains the same stand-down `notify-stop.sh` already carries, now that Canopy genuinely replaces the event.

## Copied, not shared

Four files come from Pager verbatim-with-renames: `shortenWithLLM`, `NotificationHistoryItem`, `HistoryStore`, `HistoryUpdateBridge`. This is the third time this project has chosen copying over sharing, and the reason has not changed: the two apps ship separately, diverge by design, and a shared package would couple their release cycles to buy deduplication of code that is already stable. **The accepted cost is drift**, and the mitigation is the same — each copied file names its origin in a header comment so the two can be diffed.

## Known limits, accepted

- **History is per-device and local.** A second phone would start empty. `HistoryStore` is an App Group container, not a server.
- **`maxItems = 100`, oldest dropped.** Pager's number, kept without re-deriving it.
- **A notification that APNs drops is not in the history.** The NSE only runs for delivered pushes; there is no reconciliation against the relay.
- **The summary costs a model call per long notification.** Pager pays this already and finds it worth it; the timeout means a slow call degrades to the truncated banner rather than delaying the push.

## Related

- `2026-09-03-canopy-mobile-design.md` — the roster and reply design this extends.
- `~/repos/Personal/Pager` — the origin of every copied file. Primary for how those pieces behave.
