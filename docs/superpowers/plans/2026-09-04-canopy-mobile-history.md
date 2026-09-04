# Canopy Mobile — History, Detail and Phone-Answerable Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone keeps every notification it receives, shows what actually finished, lets you reply from that detail, and lets you answer a permission request with Allow or Deny.

**Architecture:** The completion notification carries the assistant's final text, which a `result` frame already contains. A Notification Service Extension writes each delivered push into an App Group container before the banner shows, so an untapped notification is still recorded. A permission request becomes a notification with Allow/Deny actions whose decision travels back down the publisher socket and is injected as a `tool_permission_response`, not as a user turn.

**Tech Stack:** Swift 6 / SwiftUI (macOS + iOS), a Notification Service Extension, App Groups, Cloudflare Workers + Durable Objects, APNs.

**Spec:** `docs/superpowers/specs/2026-09-04-canopy-mobile-history-design.md`

## Global Constraints

- **Three repos.** `Canopy` (jj-colocated — `jj`, never `git`, for anything that writes), `Canopy-Mobile` (git, branch off `notify-reply`), `Pager` (one hook line).
- **Never print, log, or commit a secret** — not its value, prefix, suffix, or length. `SHARED_SECRET`, `APNS_AUTH_KEY` and `ANTHROPIC_API_KEY` are already set on the relay; none may appear anywhere.
- **Reply text and assistant text are user content.** They may cross the network in a push payload and be stored in the App Group container. They must never reach a log line.
- App Group: `group.sh.saqoo.canopy-app` (registered). Bundle: `sh.saqoo.canopy-app`. Team: `VCFY2GFR89`. Device: `88CF0177-6AA8-5D02-926C-27E21B989A53`, destination `platform=iOS,id=00008150-001C65CC1E40401C`.
- **A permission decision is NOT a user turn.** It must not go through `requestPhoneReply`, must not take the busy-shim guard, and must not appear in the transcript as typed text.
- Files copied from Pager carry a header comment naming their origin, so the two copies can be diffed later.
- The probe floor `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml` is raised to the **measured** count whenever assertions are added — read it off a run, never compute it.

---

## File Structure

**Canopy**
- `Sources/Canopy/ShimProcess.swift` — modified in three places: pass the `result` text to the completion push; carry the tool name and request text on the `.asking` push; a new `applyPermissionDecision(requestId:decision:)` beside `requestPhoneReply`.
- `Sources/Canopy/Roster/RosterReply.swift` — modified. The envelope gains a decision variant; the pure routing decision grows a case.
- `Sources/Canopy/_SidebarLogicProbe.swift` — assertions for the new pure surface.

**Canopy-Mobile — worker**
- `worker/src/llm.ts` — **new.** `shortenWithLLM`, copied from Pager.
- `worker/src/index.ts`, `types.ts`, `machine.ts` — `bodyFull` and the decision envelope.

**Canopy-Mobile — app**
- `Sources/Shared/NotificationHistoryItem.swift`, `HistoryStore.swift`, `HistoryUpdateBridge.swift` — **new**, copied from Pager.
- `Sources/CanopyMobileNotificationService/NotificationService.swift` — **new target.**
- `Sources/HistoryView.swift`, `HistoryDetailView.swift` — **new.**
- `Sources/PushRegistrar.swift` — notification category with Allow/Deny; action handling.
- `project.yml` — the extension target, both entitlements.

**Pager**
- `hooks/permission-request.sh` — one line.

---

## Task 1: Capture the permission-response wire shape

Everything in Tasks 7-9 depends on one fact nobody has measured: what the webview posts when a human clicks Allow. The extension bundle is minified (`tool_permission_response",result:q`), so the value of `result` cannot be read from it. **Capture it instead of guessing** — this is the same technique that settled the roster's wire contract.

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift` (temporary logging, removed in the same task)
- Create: `docs/superpowers/specs/2026-09-04-permission-response-capture.md`

**Interfaces:**
- Produces: the exact JSON a permission decision carries — the message `type`, the field holding the request id, and every legal value of the decision field. Tasks 7-9 consume it.

- [ ] **Step 1: Find where webview→host messages arrive**

```bash
grep -n 'func userContentController' Sources/Canopy/ShimProcess.swift
```
Expected: one match. Every message the webview posts passes through it.

- [ ] **Step 2: Log permission responses only**

Inside that function, before the existing dispatch, add:

```swift
// TEMPORARY — capture only, removed at the end of this task. Logs the
// whole message ONLY for tool_permission_response, whose shape is not
// readable from the minified extension bundle. It carries a decision and
// a request id, no conversation text.
if let dict = message.body as? [String: Any],
   let inner = dict["message"] as? [String: Any],
   inner["type"] as? String == "tool_permission_response",
   let data = try? JSONSerialization.data(withJSONObject: inner),
   let text = String(data: data, encoding: .utf8) {
    logger.notice("PERMCAP \(text, privacy: .public)")
}
```

If the message nests differently, adjust the unwrapping — read the surrounding code first; do not assume the shape of the envelope.

- [ ] **Step 3: Build and capture a real decision**

```bash
./scripts/build_debug_stable.sh
open build/Build/Products/Debug/Canopy.app
```
In that Canopy, open a session and run something that raises a permission prompt (for example a `Bash` command in a directory with no standing approval). **Click Allow.** Then:

```bash
/usr/bin/log show --predicate 'process == "Canopy" AND subsystem == "sh.saqoo.Canopy"' --last 3m --style compact --info | grep PERMCAP
```
Repeat for **Deny**, and for **Allow Always** if that button is offered. Each click is one captured line.

- [ ] **Step 4: Write the capture down**

Create `docs/superpowers/specs/2026-09-04-permission-response-capture.md` containing the verbatim captured JSON for each button, the extension version it came from (`ls -d ~/.vscode/extensions/anthropic.claude-code-*`), and a one-line statement of which field is the request id and which is the decision. **If a button produced no line, say so** — an unobserved case is not a case you know.

- [ ] **Step 5: Remove the logging and commit**

Delete the temporary block. Rebuild, confirm `** BUILD SUCCEEDED **`, then:

```bash
jj describe -r @ -m "Capture the permission-response wire shape

The extension bundle is minified, so the decision field could not be read
from it. Captured from a real click instead."
jj new
```

---

## Task 2: The completion notification carries the assistant's text

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift` (`postTaskCompletedNotification`, ~:4903, and its `result`-branch call site)

**Interfaces:**
- Produces: `RosterNotifier.post` is called with the assistant's final text as `body`. Task 4 consumes it as `bodyFull`.

- [ ] **Step 1: Find the result text**

```bash
grep -n 'postTaskCompletedNotification' Sources/Canopy/ShimProcess.swift
```
Expected: a definition and one call site inside the `result` handling. Read the surrounding code and find the parsed `result` frame — it carries a `"result"` string field holding the model's final text (measured 2026-09-04 against a live CLI: `{"has_result_field": true, "result": "banana"}`).

- [ ] **Step 2: Pass it through**

Give `postTaskCompletedNotification` a parameter:

```swift
/// - Parameter finalText: the `result` frame's own `result` field — the
///   model's last message. Passed in rather than accumulated: the frame is
///   already in hand at this call site, so there is no stream to buffer and
///   no JSONL to re-read, and therefore no race with the CLI's flush.
private func postTaskCompletedNotification(finalText: String?) {
```

The LOCAL macOS banner keeps its existing wording and its `!NSApp.isActive` gate — **do not change what the Mac shows.** Only the phone push gains the text:

```swift
    if let session = boundSession {
        RosterNotifier.post(kind: .completed,
                            sessionId: session.id.uuidString,
                            title: "Canopy",
                            body: finalText?.isEmpty == false ? finalText! : body)
    }
```

so a turn that produced no text still sends the old summary rather than an empty push.

- [ ] **Step 3: Build and verify nothing regressed**

```bash
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | tail -1
```
Expected: `** BUILD SUCCEEDED **` and `0 failed` with the count unchanged.

- [ ] **Step 4: Commit**

```bash
jj describe -r @ -m "Send the assistant's final text in the completion push

The result frame already carries it, and postTaskCompletedNotification is
called from that same branch — no accumulation, no JSONL re-read, no race.
The local macOS banner is unchanged."
jj new
```

---

## Task 3: The asking notification carries the request

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift` (the `pendingPermissionRequestIds.insert` site, ~:3250)

**Interfaces:**
- Produces: the `.asking` push carries the tool name, the request's text, and **the request id** — Task 8's Allow/Deny needs the id to answer with.

- [ ] **Step 1: Read what the request message holds**

```bash
grep -n -B5 -A20 'tool_permission_request' Sources/Canopy/ShimProcess.swift | head -40
```
The handler already extracts `requestId` and a tool name. Find what else the message carries — the tool input is what makes the notification worth reading.

- [ ] **Step 2: Extend the notifier call**

`RosterNotifier.post` gains an optional `requestId`. At the insert site, inside the existing `isNewPermissionRequest` guard:

```swift
    RosterNotifier.post(kind: .asking,
                        sessionId: session.id.uuidString,
                        title: toolName.isEmpty ? "Canopy — needs you" : "Canopy — \(toolName)",
                        body: requestSummary,
                        requestId: requestId)
```

where `requestSummary` is the tool's input rendered as text, truncated to 2000 characters at the Canopy end so the relay's own 3000 cap is never the thing that decides.

- [ ] **Step 3: Build, probe, commit**

```bash
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | tail -1
```
Expected: SUCCEEDED, `0 failed`, count unchanged. Then `jj describe` / `jj new` with a message saying the asking push now carries what is being asked, and why the id rides along.

---

## Task 4: The relay summarises and forwards the full body

**Files:**
- Create: `worker/src/llm.ts`
- Modify: `worker/src/index.ts`, `worker/src/types.ts`, `worker/src/index.test.ts`

**Interfaces:**
- Consumes: `POST /notify` gains `bodyFull` and optional `requestId`.
- Produces: an APNs payload carrying `bodyFull`, `requestId`, and a banner that is either the LLM summary or a truncation.

- [ ] **Step 1: Copy the summariser**

Read `~/repos/Personal/Pager/worker/src/index.ts` and copy `shortenWithLLM` and every helper it calls into `worker/src/llm.ts`, with a header comment naming the origin. It calls `claude-haiku-4-5` at `api.anthropic.com` with `env.ANTHROPIC_API_KEY` behind an `AbortController` timeout. **The timeout is the point** — a slow call must degrade to a truncation, never delay the push.

- [ ] **Step 2: Extend the types**

```typescript
export interface NotifyBody {
  machine: string;
  sessionId: string;
  title: string;
  body: string;
  kind: "completed" | "asking";
  /** The full text, before any shortening. Rides in the push payload so the
   *  Notification Service Extension can store it — the extension has no
   *  credential to fetch anything with. */
  bodyFull?: string;
  /** Present only for `kind: "asking"`. The id the phone answers with. */
  requestId?: string;
}
```

- [ ] **Step 3: Write the failing tests**

```typescript
it("notify rejects a requestId on a completed push", async () => {
  const res = await SELF.fetch("https://x/notify", {
    method: "POST",
    headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ machine: "m1", sessionId: "s1", title: "t", body: "b", kind: "completed", requestId: "r1" }),
  });
  expect(res.status).toBe(400);
});

it("notify requires a requestId on an asking push", async () => {
  const res = await SELF.fetch("https://x/notify", {
    method: "POST",
    headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ machine: "m1", sessionId: "s1", title: "t", body: "b", kind: "asking" }),
  });
  expect(res.status).toBe(400);
});
```

Both encode the same rule from the other side: **a decision needs something to answer, and a completion has nothing to answer.**

- [ ] **Step 4: Run them, watch them fail**

Run: `cd worker && npx vitest run`
Expected: two failures, both returning 503 (no device) rather than 400.

- [ ] **Step 5: Implement**

In `/notify`, after the existing `kind` validation:

```typescript
  if (body.kind === "asking" && !body.requestId) return json({ error: "asking requires requestId" }, 400);
  if (body.kind === "completed" && body.requestId) return json({ error: "completed takes no requestId" }, 400);
```

and build the payload with `bodyFull` truncated to the existing 3000-character cap, a banner from `shortenWithLLM` when the text exceeds 100 characters and a plain truncation otherwise, and `category` set to `"CANOPY_PERMISSION"` for an asking push so the phone can attach Allow/Deny actions to exactly those.

- [ ] **Step 6: Verify and commit**

Run: `cd worker && npx vitest run && npx tsc --noEmit`
Expected: all pass, tsc clean. Do NOT deploy — deployment is a separate, deliberate step.

```bash
git add worker/src/llm.ts worker/src/index.ts worker/src/types.ts worker/src/index.test.ts
git commit -m "Summarise long notifications and forward the full body

bodyFull rides in the push payload rather than KV: the relay must not
accumulate conversation text keyed by device, and the Notification Service
Extension has no credential to fetch it with."
```

---

## Task 5: The app group, the shared history types, and the extension target

**Files:**
- Create: `Sources/Shared/NotificationHistoryItem.swift`, `Sources/Shared/HistoryStore.swift`, `Sources/Shared/HistoryUpdateBridge.swift`
- Create: `Sources/CanopyMobileNotificationService/NotificationService.swift`, `Info.plist`
- Modify: `project.yml`

**Interfaces:**
- Produces: `HistoryStore.append(_:)`, `.loadAll()`, `.item(withId:)`, `.delete(id:)`, `.deleteAll()`, and `HistoryUpdateBridge.didUpdate` — Task 6's views consume all of them.

- [ ] **Step 1: Copy the three shared files**

From `~/repos/Personal/Pager/Sources/Shared/`. Change `appGroupID` to `group.sh.saqoo.canopy-app` and the Darwin notification name to `sh.saqoo.canopy-app.historyDidUpdate`. **Keep `maxItems = 100`** — Pager's number, adopted without re-deriving it, and say so in a comment.

Trim `NotificationHistoryItem` to the fields this app actually sends: `id`, `receivedAt`, `title`, `body`, `bodyShort`, `machine`, `sessionId`, `kind`, `requestId`, and a mutable `decision`/`decidedAt` pair for an answered permission. **Drop Pager's `project`, `toolName` and `source`** unless the payload actually carries them — a field nothing writes is a field that will be wrong.

- [ ] **Step 2: Add the extension target**

In `project.yml`, add a `CanopyMobileNotificationService` target of type `app-extension.notification-service`, with `group.sh.saqoo.canopy-app` in its entitlements, and add the same group to the app target's existing entitlements block. Add the extension as a dependency of the app. Mirror the shape of Pager's `project.yml`.

- [ ] **Step 3: Write the extension**

`didReceive` reads `machine`, `sessionId`, `kind`, `requestId` and `bodyFull` out of `request.content.userInfo`, builds a `NotificationHistoryItem` (falling back to `aps.alert.body` when `bodyFull` is absent), calls `HistoryStore.append`, posts the Darwin update, and then passes the content through. **Every failure logs; none is swallowed** — a history that silently stops recording is indistinguishable from no notifications arriving. **Never log the body.**

- [ ] **Step 4: Build and install**

```bash
xcodegen generate
xcodebuild -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -destination 'platform=iOS,id=00008150-001C65CC1E40401C' \
  -derivedDataPath build-device -allowProvisioningUpdates build
```
Expected: `** BUILD SUCCEEDED **`. Automatic signing creates the extension's own App ID. If the device is unplugged, say so and skip the install; do not fabricate one.

- [ ] **Step 5: Commit**

```bash
git add Sources/Shared Sources/CanopyMobileNotificationService project.yml
git commit -m "Record every delivered notification in an App Group container

A push that is never tapped never reaches the app, so the Notification
Service Extension is the only place that sees it. HistoryStore and its
companions are copied from Pager rather than shared: the two apps ship
separately and diverge by design."
```

---

## Task 6: History list, detail, and reply from the detail

**Files:**
- Create: `Sources/HistoryView.swift`, `Sources/HistoryDetailView.swift`
- Modify: `Sources/CanopyMobileApp.swift`, `Sources/ReplySheet.swift`

**Interfaces:**
- Consumes: `HistoryStore`, `HistoryUpdateBridge.didUpdate`.
- Produces: a reply sheet that is given the notification's body as context.

- [ ] **Step 1: The list**

`HistoryView` loads `HistoryStore.loadAll()` on appear and on every `HistoryUpdateBridge.didUpdate`, newest first, one row per item: the title, `bodyShort ?? body` truncated to one line, and a relative timestamp. An answered permission shows its decision. **Empty state says so plainly** rather than rendering nothing.

- [ ] **Step 2: The detail**

`HistoryDetailView` renders the full `body`, the machine and session, and — for `kind == "asking"` that is still unanswered — **Allow** and **Deny** buttons. For any item it offers **Reply**, which opens `ReplySheet`.

- [ ] **Step 3: Give the reply sheet its context**

`ReplySheet` gains an optional `context: String`. When present it renders above the text field, scrollable, secondary-styled. **That is the whole point of this plan** — the composer must show what it is answering.

- [ ] **Step 4: Reach it from the roster**

The existing tab or navigation gains History. A row tap in the roster still opens the reply sheet directly, now with the most recent history item for that session as context when one exists.

- [ ] **Step 5: Build, install, verify on device**

Build and install as in Task 5. Then: cause a real completion, confirm a row appears in History with the assistant's text, open it, and reply from there. **Report exactly what you could not verify** if the device is unreachable.

- [ ] **Step 6: Commit**

```bash
git add Sources/HistoryView.swift Sources/HistoryDetailView.swift Sources/CanopyMobileApp.swift Sources/ReplySheet.swift
git commit -m "Show what finished, and reply from it

The reply sheet showed a session title and nothing else, so answering
meant guessing. It now renders the notification's body as context."
```

---

## Task 7: Carry a decision back to the Mac

**Files:**
- Modify: `worker/src/types.ts`, `worker/src/machine.ts`, `worker/src/index.ts`, `worker/src/index.test.ts`

**Interfaces:**
- Consumes: Task 1's captured wire shape.
- Produces: `POST /decide {machine, sessionId, requestId, decision}` and a `DecisionEnvelope {type: "decision", sessionId, requestId, decision}` written down the publisher socket.

- [ ] **Step 1: Read Task 1's capture**

Read `docs/superpowers/specs/2026-09-04-permission-response-capture.md` in the Canopy repo. **The legal values of `decision` come from that file, not from this plan** — this plan could not know them.

- [ ] **Step 2: Write the failing tests**

Mirror `/reply`'s two tests: a decision for a machine with no publisher returns 503, and a decision whose value is not one of the captured legal values returns 400. Use the values from the capture document.

- [ ] **Step 3: Run them, watch them fail**

Run: `cd worker && npx vitest run` — expected: two failures, both 404 (route absent).

- [ ] **Step 4: Implement**

`deliverReply` already finds publishers through `ctx.getWebSockets()` and the serialized attachment; **reuse it** by widening it to take either envelope rather than writing a second finder — one place that knows how to reach a publisher.

- [ ] **Step 5: Verify and commit**

`npx vitest run && npx tsc --noEmit` clean. Commit with a message saying a decision is not a reply and travels as its own envelope.

---

## Task 8: Answer the request on the Mac

**Files:**
- Modify: `Sources/Canopy/Roster/RosterReply.swift`, `Sources/Canopy/ShimProcess.swift`, `Sources/Canopy/CanopyApp.swift`, `Sources/Canopy/_SidebarLogicProbe.swift`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `DecisionEnvelope` from Task 7, the wire shape from Task 1.
- Produces: `ShimProcess.applyPermissionDecision(requestId:decision:) -> Bool`.

- [ ] **Step 1: Extend the pure router**

`RosterReply` gains a decision case and `RosterReply.decisionTarget(for:in:)`, matching a session the same way `target` does. Keep it pure so the probe reaches it.

- [ ] **Step 2: Write the failing probe assertions**

Four, mirroring the reply ones: routes to the addressed session; refuses an unknown decision value; refuses an envelope whose `requestId` is empty; and a session id from a previous launch matches nothing. Then add a **two-session** fixture where the envelope addresses the second — the reply block's own deferred minor, folded in here so the same gap is not left twice.

- [ ] **Step 3: Run the probe and watch them fail**

Expected: the new assertions fail; the existing ones stay green.

- [ ] **Step 4: Implement the injection**

```swift
/// Answers an outstanding permission request from the phone.
///
/// NOT a user turn. It takes no busy-shim guard, sets no reply latch, and
/// writes nothing to the transcript — it responds to a request the CLI is
/// already blocked on. Routing is by `requestId`, which is per process: a
/// decision for an id no longer in `pendingPermissionRequestIds` is dropped
/// and logged, never applied to whatever is outstanding now, because that
/// would approve a tool the user never saw.
@discardableResult
func applyPermissionDecision(requestId: String, decision: String) -> Bool {
```

The message it sends is the one captured in Task 1. Wire it in `AppDelegate` beside the existing `onReply`, logging every non-injecting branch the way that one now does.

- [ ] **Step 5: Verify, mutation-check, raise the floor**

Build, run the probe, confirm `0 failed`. **Mutation-check the two-session assertion**: make `decisionTarget` return `sessions.first`, rebuild, confirm it FAILS, revert, rebuild. Report the mutation and its verbatim failing line. Write the **measured** count into `EXPECTED_ASSERTIONS`.

- [ ] **Step 6: Commit**

---

## Task 9: The phone answers, and the hook stands down

**Files:**
- Modify: `Sources/PushRegistrar.swift`, `Sources/HistoryDetailView.swift`, `Sources/RosterClient.swift`
- Modify: `~/repos/Personal/Pager/hooks/permission-request.sh`

- [ ] **Step 1: Register the category and actions**

Copy the shape from `~/repos/Personal/Pager/Sources/Pager/AppDelegate.swift`'s `registerNotificationCategory`. **Keep its comment and its reasoning**: no `.authenticationRequired`, because that option queues the action until the iPhone is unlocked, which means an Apple Watch tap on a locked phone never reaches the delegate. Category identifier `CANOPY_PERMISSION`, actions `allow` and `deny` (the latter `.destructive`).

- [ ] **Step 2: Handle the action**

In `userNotificationCenter(_:didReceive:withCompletionHandler:)`, an action identifier of `allow` or `deny` posts `POST /decide` with the `machine`, `sessionId` and `requestId` from `userInfo`, then updates the stored history item's `decision`/`decidedAt`. A **tap** (no action) keeps opening the detail.

- [ ] **Step 3: The same buttons in the detail view**

`HistoryDetailView`'s Allow/Deny call the same client method, so the two paths cannot diverge.

- [ ] **Step 4: Stand the hook down**

In `~/repos/Personal/Pager/hooks/permission-request.sh`, add the same guard `notify-stop.sh` carries — `CANOPY_PANE` present **and** `--source claude`, draining stdin before exiting. Rewrite the file's comment: Canopy now genuinely replaces this event, which is the condition the earlier decision to leave it alone was explicitly conditioned on.

- [ ] **Step 5: Verify end to end on the device**

Cause a real permission request in a Canopy session. Confirm: **exactly one** notification arrives (Canopy Mobile's, not Pager's); Allow from the lock screen unblocks the session; the history item shows the decision. Then confirm a **terminal** `claude` session's permission request still reaches Pager.

- [ ] **Step 6: Commit in both repos**

---

## Verification of the whole feature

- [ ] One event, one buzz: a Canopy completion notifies only Canopy Mobile; a terminal `claude` completion notifies only Pager; a Canopy permission request notifies only Canopy Mobile; a terminal one only Pager.
- [ ] A notification that is never tapped still appears in History.
- [ ] The reply sheet shows the assistant's text.
- [ ] Allow from the lock screen unblocks a session that was waiting.
- [ ] Canopy's probe reports `0 failed` and `EXPECTED_ASSERTIONS` equals the measured count; the Worker is green with `tsc` clean.

## Known limits, accepted

- **A decision for a stale `requestId` is dropped.** Correct, and it means a permission answered after the session restarted does nothing — silently to the phone, which has no ack channel. The Mac logs it.
- **History is per-device.** A second phone starts empty.
- **The summary costs a model call.** Bounded by the timeout, which degrades to truncation.
