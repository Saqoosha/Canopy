# Canopy Mobile — Notifications and Reply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Canopy session that finishes a turn or raises a question pushes a notification to the phone, and the phone can answer it with free text that lands in that session as a real user turn.

**Architecture:** Canopy already holds a publisher WebSocket to its `MachineDO`. Notifications go *out* over HTTP to a new `/notify` route on the same relay, which fans them to APNs. Replies come *back down that existing publisher socket* — the Mac needs no inbound port and no polling, and the socket is already authenticated and hibernation-safe. Claude Code's own hooks stand down for Canopy-hosted sessions so one event never buzzes twice.

**Tech Stack:** Swift 6 / SwiftUI (macOS + iOS), Cloudflare Workers + Durable Objects, APNs (token-based, ES256 JWT), bash hooks.

**Spec:** `docs/superpowers/specs/2026-09-03-canopy-mobile-design.md` (build order steps 4-5)

## Global Constraints

- **Three repos.** `Canopy` (Swift, jj-colocated — use `jj`, never `git` for VCS ops), `Canopy-Mobile` (iOS app + `worker/`, plain git), `Pager` (hook scripts only).
- **Never print, log, or commit a secret** — not its value, prefix, suffix, or length. APNs keys and `SHARED_SECRET` go in via `wrangler secret put`, never a file.
- **APNs credentials are shared with Pager, not re-issued.** An APNs auth key is team-wide. `APNS_KEY_ID = SRH3669YH6`, `APNS_TEAM_ID = VCFY2GFR89`. `APNS_BUNDLE_ID` for this relay is `sh.saqoo.canopy-mobile` — different from Pager's, which is why this is a second Worker.
- **Every relay route stays behind `authorized()`**, and the fail-closed `SHARED_SECRET`-missing 503 stays ahead of every other branch.
- **A reply is a REAL user turn.** Reuse `requestKeepAlive`'s busy-shim guard; **never** reuse its swallow latches or its replay filter — a keep-alive deliberately hides itself, and a reply must appear in the transcript exactly like something typed at the Mac.
- **Do NOT implement dark mode** anywhere.
- The probe floor `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml` must be raised to the measured count whenever probe assertions are added — read the count off a local probe run, never compute it.

---

## File Structure

**Canopy**
- `Sources/Canopy/Roster/RosterNotifier.swift` — **new.** Posts one notification event to the relay. One responsibility: compose the payload and POST it. Knows nothing about when to fire.
- `Sources/Canopy/Roster/RosterReply.swift` — **new.** The `ReplyEnvelope` wire type plus the pure routing decision (`RosterReply.target(for:in:)`) that maps an incoming envelope to an `OpenSession`. Pure, so the probe can exercise it.
- `Sources/Canopy/Roster/RosterPublisher.swift` — modified. Gains a receive loop on the publisher socket and hands decoded envelopes to a delegate closure.
- `Sources/Canopy/ShimProcess.swift` — modified in three places: `CANOPY_PANE` into the spawn environment, a phone push beside the existing local notification, and `requestPhoneReply(text:)` beside `requestKeepAlive`.
- `Sources/Canopy/_SidebarLogicProbe.swift` — modified. Assertions for the pure pieces.

**Canopy-Mobile — worker**
- `worker/src/apns.ts` — **new.** Copied from Pager's `sendPush` and its JWT helper. Isolated so the two copies can be diffed later.
- `worker/src/index.ts` — modified. Adds `/register`, `/notify`, `/reply`.
- `worker/src/machine.ts` — modified. `MachineDO` gains `deliverReply()`, which writes down the publisher socket.
- `worker/src/types.ts` — modified. `NotifyBody`, `ReplyBody`, `ReplyEnvelope`.

**Canopy-Mobile — app**
- `Sources/PushRegistrar.swift` — **new.** APNs registration and token upload. One responsibility.
- `Sources/CanopyMobileApp.swift` — modified. Installs the registrar; opens the reply sheet when a notification is tapped.
- `Sources/ReplySheet.swift` — **new.** The free-text composer.
- `Sources/RosterClient.swift` — modified. `sendReply(machine:sessionId:text:)`.
- `project.yml` — modified. `aps-environment` entitlement.

**Pager**
- `hooks/notify-stop.sh`, `hooks/notify-notification.sh`, `hooks/permission-request.sh` — one line each.

---

## Task 1: Hooks stand down for Canopy-hosted sessions

Without this, a session stopping inside Canopy fires twice: the hook to Pager, and Canopy to Canopy Mobile.

**Files:**
- Modify: `~/repos/Personal/Pager/hooks/notify-stop.sh`
- Modify: `~/repos/Personal/Pager/hooks/notify-notification.sh`
- Modify: `~/repos/Personal/Pager/hooks/permission-request.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the contract that `CANOPY_PANE` present in a hook's environment means "Canopy owns this session's notifications". Task 2 sets that variable.

- [ ] **Step 1: Verify the hooks are the symlink targets**

```bash
ls -l ~/.claude/hooks/notify-stop.sh ~/.claude/hooks/notify-notification.sh ~/.claude/hooks/permission-request.sh
```
Expected: each is a symlink into `~/repos/Personal/Pager/hooks/`. If any is a real file, STOP and report — editing the repo copy would then change nothing.

- [ ] **Step 2: Add the stand-down line to each of the three scripts**

Insert immediately after the `#!/bin/bash` line and its comment block, before any other logic, in all three files:

```bash
# Canopy hosts this session and sends its own notification (see
# docs/superpowers/specs/2026-09-03-canopy-mobile-design.md in the Canopy
# repo). Without this, one event buzzes the phone twice. A terminal session
# has no such variable and behaves exactly as before, and so does every
# codex/cursor session.
[ -n "$CANOPY_PANE" ] && exit 0
```

- [ ] **Step 3: Prove the guard fires and that it is scoped**

```bash
CANOPY_PANE=0 bash ~/repos/Personal/Pager/hooks/notify-stop.sh --source claude </dev/null; echo "with CANOPY_PANE -> exit $?"
```
Expected: `exit 0` and **no** network call. Then:
```bash
env -u CANOPY_PANE bash -c 'echo "$CANOPY_PANE"'
```
Expected: an empty line — confirming the unset case reaches the rest of the script unchanged. Do not run the unset case against the live Worker.

- [ ] **Step 4: Commit**

```bash
cd ~/repos/Personal/Pager
git add hooks/notify-stop.sh hooks/notify-notification.sh hooks/permission-request.sh
git commit -m "Stand down for Canopy-hosted sessions

Canopy sends its own notification for a session it hosts, so the hook
firing as well buzzes the phone twice for one event. A terminal session
has no CANOPY_PANE and is unaffected, and neither is codex or cursor."
```

---

## Task 2: Canopy exports CANOPY_PANE at spawn

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift` (the environment assembly at ~1286-1411)

**Interfaces:**
- Consumes: Task 1's contract.
- Produces: `CANOPY_PANE` in every shim's environment, value = the pane index as a decimal string, or `"-"` when the session has no pane. Task 5 reads the same session identity.

- [ ] **Step 1: Find the assembly block**

```bash
grep -n 'var env = ProcessInfo.processInfo.environment' Sources/Canopy/ShimProcess.swift
grep -n 'proc.environment = env' Sources/Canopy/ShimProcess.swift
```
Expected: two line numbers ~1286 and ~1411. Every `CANOPY_*` assignment lives between them.

- [ ] **Step 2: Add the variable beside the existing ones**

Immediately after the last existing `env["CANOPY_..."]` assignment, add:

```swift
// Marks this CLI session as hosted by Canopy. Claude Code's hooks inherit
// the CLI's environment (measured), and Pager's three hook scripts exit
// early when they see this — Canopy sends the notification itself, with the
// pane and session identity a hook cannot know. The value is informational;
// only its PRESENCE is load-bearing, so "-" is a legitimate value and must
// not be an empty string, which would read as absent.
env["CANOPY_PANE"] = "-"
```

The value is corrected to a real index in Step 3; `"-"` is the shape for a session with no pane.

- [ ] **Step 3: Set the real index where the pane is known**

`ShimProcess` does not own the pane strip. Add to `SessionStore`, next to the other pane-assignment helpers:

```swift
/// The pane index a session currently occupies, or nil when it has none.
/// Used only to label a shim's `CANOPY_PANE`; not an invariant anything
/// else may rely on, since a pane can close under a running shim.
func paneIndex(forSession id: OpenSession.ID) -> Int? {
    panes.firstIndex { if case .session(let s) = $0.content { return s == id } else { return false } }
}
```

and in `ShimProcess`, replace the `"-"` literal with:

```swift
env["CANOPY_PANE"] = boundSession
    .flatMap { session in store?.paneIndex(forSession: session.id) }
    .map(String.init) ?? "-"
```

If `ShimProcess` holds no `store` reference, pass the index in at spawn instead of adding one — do not introduce a new strong reference to `SessionStore` from `ShimProcess`.

- [ ] **Step 4: Build and verify on a live session**

```bash
./scripts/build_debug_stable.sh
open build/Build/Products/Debug/Canopy.app
```
Then in that Canopy, open a session and run in it: `echo "$CANOPY_PANE"`.
Expected: `0` (or the pane's index). In a terminal session outside Canopy the same command prints an empty line.

- [ ] **Step 5: Commit**

```bash
jj describe -r @ -m "Mark Canopy-hosted CLI sessions with CANOPY_PANE

Claude Code's hooks inherit the CLI's environment, so Pager's three hook
scripts can stand down for a session Canopy already notifies about. Only
the variable's presence is load-bearing; a session with no pane gets '-'
rather than an empty string, which would read as absent."
jj new
```

---

## Task 3: The relay sends pushes

**Files:**
- Create: `worker/src/apns.ts`
- Modify: `worker/src/index.ts`
- Modify: `worker/src/types.ts`
- Test: `worker/src/index.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `POST /register {token}`; `POST /notify {machine, sessionId, title, body, kind}` where `kind` is `"completed" | "asking"`; and `sendPush(env, deviceToken, payload)` from `apns.ts`.

- [ ] **Step 1: Copy Pager's sender**

```bash
cd ~/repos/Personal/Canopy-Mobile
# Read Pager's implementation and copy sendPush plus every helper it calls
# (JWT signing, sendPushDirect, the sandbox cache) into worker/src/apns.ts.
grep -n 'function sendPush\|function sendPushDirect\|function .*[Jj]wt\|readCachedApnsEnv' ~/repos/Personal/Pager/worker/src/index.ts
```

`apns.ts` must export exactly:

```typescript
export async function sendPush(
  env: ApnsEnv,
  deviceToken: string,
  payload: object,
  useSandbox?: boolean,
): Promise<Response>
```

with

```typescript
export interface ApnsEnv {
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  APNS_AUTH_KEY: string;
  APNS_USE_SANDBOX?: string;
  MACHINES: KVNamespace;   // reused for the sandbox-environment cache
}
```

Head the file with:

```typescript
// Copied from Pager's worker/src/index.ts (sendPush and its helpers), not
// imported: the two Workers diverge by design — this one grows a DO, a
// roster and a WebSocket, that one stays a notification relay — and an
// APNs auth key is team-wide, so the credential is shared while the code
// is not. The accepted cost is that these two copies will drift; diff them
// against Pager before changing anything about JWT signing or the retry.
```

- [ ] **Step 2: Add the types**

In `worker/src/types.ts`:

```typescript
/** What Canopy posts to /notify. */
export interface NotifyBody {
  machine: string;
  /** OpenSession.ID as a UUID string — the same one the roster carries. */
  sessionId: string;
  title: string;
  body: string;
  /** Which activity raised this. Only these two push. */
  kind: "completed" | "asking";
}
```

- [ ] **Step 3: Write the failing tests**

Append to `worker/src/index.test.ts`:

```typescript
it("register rejects a non-hex token", async () => {
  const res = await SELF.fetch("https://x/register", {
    method: "POST",
    headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ token: "NOT-HEX" }),
  });
  expect(res.status).toBe(400);
});

it("notify is refused when no device has registered", async () => {
  const res = await SELF.fetch("https://x/notify", {
    method: "POST",
    headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ machine: "m1", sessionId: "s1", title: "t", body: "b", kind: "completed" }),
  });
  expect(res.status).toBe(503);
});

it("notify rejects an unknown kind", async () => {
  const res = await SELF.fetch("https://x/notify", {
    method: "POST",
    headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ machine: "m1", sessionId: "s1", title: "t", body: "b", kind: "gossip" }),
  });
  expect(res.status).toBe(400);
});
```

- [ ] **Step 4: Run them and watch them fail**

Run: `cd worker && npx vitest run`
Expected: three failures, each a 404 (route not found) rather than the expected status.

- [ ] **Step 5: Add the routes**

In `worker/src/index.ts`, inside the authorized block, before the final 404:

```typescript
if (url.pathname === "/register" && request.method === "POST") {
  const body = await request.json<{ token?: string }>().catch(() => null);
  if (!body?.token) return json({ error: "token required" }, 400);
  // APNs tokens are lowercase hex; length varies by device and OS, so the
  // shape is checked and the length deliberately is not.
  if (!/^[0-9a-f]+$/.test(body.token)) return json({ error: "invalid token format" }, 400);
  await env.MACHINES.put("device_token", body.token);
  return json({ ok: true });
}

if (url.pathname === "/notify" && request.method === "POST") {
  const body = await request.json<NotifyBody>().catch(() => null);
  if (!body?.machine || !body.sessionId) return json({ error: "machine and sessionId required" }, 400);
  if (body.kind !== "completed" && body.kind !== "asking") {
    return json({ error: "kind must be completed or asking" }, 400);
  }
  const deviceToken = await env.MACHINES.get("device_token");
  if (!deviceToken) return json({ error: "no device registered" }, 503);
  // 3000 chars keeps the whole APNs payload under the 4 KB limit, matching
  // Pager's own cap. The routing fields ride in the payload rather than in
  // KV because they are two short ids, not a conversation.
  const MAX = 3000;
  const text = body.body.length > MAX ? body.body.slice(0, MAX) + "…" : body.body;
  const payload = {
    aps: {
      alert: { title: body.title, body: text },
      sound: "default",
      "mutable-content": 1,
      category: "CANOPY_SESSION",
    },
    machine: body.machine,
    sessionId: body.sessionId,
    kind: body.kind,
  };
  return sendPush(env, deviceToken, payload);
}
```

Add the small helper if `index.ts` lacks one:

```typescript
function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
```

Extend the `Env` interface with the five APNs fields from `ApnsEnv`.

- [ ] **Step 6: Run the tests**

Run: `cd worker && npx vitest run && npx tsc --noEmit`
Expected: all tests pass, tsc clean.

- [ ] **Step 7: Add the non-secret vars and set the key**

In `wrangler.toml`, beside the existing config:

```toml
[vars]
APNS_KEY_ID = "SRH3669YH6"
APNS_TEAM_ID = "VCFY2GFR89"
APNS_BUNDLE_ID = "sh.saqoo.canopy-mobile"
APNS_USE_SANDBOX = "false"
```

Then, and **only** by hand — never in a script that echoes it:

```bash
cd worker && npx wrangler secret put APNS_AUTH_KEY
```
Paste the same `.p8` contents Pager uses.

- [ ] **Step 8: Commit**

```bash
git add worker/src/apns.ts worker/src/index.ts worker/src/types.ts worker/src/index.test.ts worker/wrangler.toml
git commit -m "Give the relay an APNs sender, /register and /notify

sendPush and its JWT helpers are copied from Pager rather than imported:
the two Workers diverge by design, while the APNs auth key is team-wide
and so is genuinely shared. The routing ids ride in the push payload —
they are two short strings, not a conversation, so KV buys nothing."
```

---

## Task 4: The phone registers for pushes

**Files:**
- Create: `Sources/PushRegistrar.swift`
- Modify: `Sources/CanopyMobileApp.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: `POST /register {token}` from Task 3.
- Produces: `PushRegistrar` (an `NSObject, UIApplicationDelegate`) that uploads the token, and `@UIApplicationDelegateAdaptor` wiring in the App.

- [ ] **Step 1: Add the entitlement**

In `project.yml`, under the `CanopyMobile` target:

```yaml
    entitlements:
      path: Sources/CanopyMobile.entitlements
      properties:
        aps-environment: development
```

`development` matches a Debug build installed by `devicectl`; a TestFlight or Release build needs `production`.

- [ ] **Step 2: Write the registrar**

Create `Sources/PushRegistrar.swift`:

```swift
import UIKit
import UserNotifications

/// Asks for notification permission, registers with APNs, and hands the
/// token to the relay. Split out of the App so the App stays about the
/// roster; this file is the only place that knows APNs exists.
///
/// The token is uploaded on EVERY launch, not only when it changes: APNs
/// reissues tokens on restore, reinstall and some OS updates, and a stale
/// one fails silently at send time — the exact invisible failure the roster
/// half already had to hunt down twice.
final class PushRegistrar: NSObject, UIApplicationDelegate {
    static var relayURL: URL?
    static var secret: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await PushRegistrar.upload(token: token) }
    }

    func application(_: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Surfaced, never swallowed: without a token every push is dropped
        // by APNs with no signal on this side.
        print("APNs registration failed: \(error.localizedDescription)")
    }

    private static func upload(token: String) async {
        guard let base = relayURL, let secret else { return }
        var request = URLRequest(url: base.appendingPathComponent("register"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }
}
```

- [ ] **Step 3: Wire it into the App**

In `Sources/CanopyMobileApp.swift`, add the adaptor beside the existing state and keep the registrar's statics fresh:

```swift
@UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar
```

and inside the existing `.onChange(of: rosterUrl)` / `.onChange(of: secret)` handlers, before `reconnect()`:

```swift
PushRegistrar.relayURL = baseURL
PushRegistrar.secret = secret
```

Also set both in the `.onChange(of: scenePhase, initial: true)` `.active` branch, so a cold launch with settings already stored uploads the token without waiting for an edit.

- [ ] **Step 4: Build, install, and verify the token reached the relay**

```bash
xcodegen generate
xcodebuild -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -destination 'platform=iOS,id=00008150-001C65CC1E40401C' \
  -derivedDataPath build-device -allowProvisioningUpdates build
xcrun devicectl device install app --device 88CF0177-6AA8-5D02-926C-27E21B989A53 \
  build-device/Build/Products/Debug-iphoneos/CanopyMobile.app
xcrun devicectl device process launch --terminate-existing \
  --device 88CF0177-6AA8-5D02-926C-27E21B989A53 sh.saqoo.canopy-mobile
```

Accept the notification prompt on the phone, then confirm the relay stored a token **without printing it**:

```bash
cd worker && npx wrangler kv key get --remote \
  --namespace-id=34a34a05b2194af6b9f2c89847a57ea1 device_token >/dev/null \
  && echo "device_token IS stored" || echo "NOT stored"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/PushRegistrar.swift Sources/CanopyMobileApp.swift project.yml
git commit -m "Register the phone for pushes

The token is uploaded on every launch, not only on change: APNs reissues
it on restore, reinstall and some OS updates, and a stale token fails
silently at send time."
```

---

## Task 5: Canopy pushes its own notifications

**Files:**
- Create: `Sources/Canopy/Roster/RosterNotifier.swift`
- Modify: `Sources/Canopy/ShimProcess.swift:4903` (`postTaskCompletedNotification`) and the `pendingPermissionRequestIds.insert` site at ~3059

**Interfaces:**
- Consumes: `POST /notify` from Task 3.
- Produces: `RosterNotifier.post(kind:sessionId:title:body:)`, callable from `ShimProcess`.

- [ ] **Step 1: Write the notifier**

Create `Sources/Canopy/Roster/RosterNotifier.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Roster")

/// Posts one notification event to the relay, which fans it to APNs.
///
/// Deliberately fire-and-forget and stateless: a dropped notification is a
/// missed buzz, and the roster's live socket already carries the same state
/// change, so nothing here is worth a retry queue.
@MainActor
enum RosterNotifier {
    enum Kind: String { case completed, asking }

    static func post(kind: Kind, sessionId: String, title: String, body: String) {
        let settings = CanopySettings.shared
        guard settings.rosterEnabled,
              let machineId = MachineIdentity.stableId(),
              var components = URLComponents(string: settings.rosterEndpoint),
              let secret = RosterPublisher.sharedSecretForNotifier()
        else { return }
        components.path = "/notify"
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "machine": machineId,
            "sessionId": sessionId,
            "title": title,
            "body": body,
            "kind": kind.rawValue,
        ])
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                logger.notice("roster notify failed: \(error.localizedDescription, privacy: .public)")
            } else if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 {
                logger.notice("roster notify returned \(code, privacy: .public)")
            }
        }.resume()
    }
}
```

In `RosterPublisher`, expose the existing private Keychain read:

```swift
/// The relay secret, for `RosterNotifier`, which posts over HTTP rather
/// than the socket and so cannot reuse the connection's own header.
static func sharedSecretForNotifier() -> String? { sharedSecret() }
```

- [ ] **Step 2: Push beside the existing local notification**

`postTaskCompletedNotification()` at line 4903 already composes exactly the right words and is called from the `result` branch. Add the phone push at the END of that method, **outside** its `guard !NSApp.isActive` — restructure so the guard covers only the local `UNUserNotificationCenter` call:

```swift
private func postTaskCompletedNotification() {
    let body = sessionTitle.isEmpty ? "Task completed" : "\(sessionTitle) — completed"

    // The phone is pushed unconditionally, while the LOCAL banner keeps its
    // `!NSApp.isActive` gate. They answer different questions: that gate
    // means "Canopy is not frontmost on this Mac", which says nothing about
    // whether a human is at this desk — walking away with Canopy frontmost
    // is exactly the case the phone exists for. The accepted cost is a buzz
    // while you are sitting at the Mac; the phone's own Focus settings are
    // the control for that, and gating on activity here would reproduce the
    // MacroPad unread bug where "app is frontmost" was mistaken for "a human
    // is looking".
    if let session = boundSession {
        RosterNotifier.post(kind: .completed,
                            sessionId: session.id.uuidString,
                            title: "Canopy",
                            body: body)
    }

    guard !NSApp.isActive else { return }
    let content = UNMutableNotificationContent()
    content.title = "Canopy"
    content.body = body
    content.sound = .default
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
        if let error { logger.error("Notification error: \(error.localizedDescription, privacy: .public)") }
    }
}
```

- [ ] **Step 3: Push when a question is raised**

At the `pendingPermissionRequestIds.insert(requestId)` site (~3059), after the insert:

```swift
// A raised hand is the one state where the notification is worth more than
// the roster row: it is the only state that cannot resolve itself.
if let session = boundSession {
    RosterNotifier.post(kind: .asking,
                        sessionId: session.id.uuidString,
                        title: "Canopy — needs you",
                        body: sessionTitle.isEmpty ? "A session is waiting" : sessionTitle)
}
```

- [ ] **Step 4: Build and verify a real push arrives**

```bash
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | tail -1
```
Expected: `--- N passed, 0 failed ---` with N unchanged from before this task.

Then launch Canopy, send any prompt in a session, and watch the phone. Expected: a banner reading `<session title> — completed` within a few seconds. If nothing arrives, read the relay's own view rather than guessing:

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npx wrangler tail canopy-mobile-relay --format json
```
`wrangler tail` prints **pretty-printed** JSON, not JSONL — parse it with `JSONDecoder().raw_decode` in a loop, not line by line, or you will read "no requests" from a file full of them.

- [ ] **Step 5: Commit**

```bash
jj describe -r @ -m "Push Canopy's own notifications to the phone

The local banner keeps its !NSApp.isActive gate and the phone push does
not: that gate means 'Canopy is not frontmost on this Mac', which says
nothing about whether a human is at the desk — walking away with Canopy
frontmost is the case the phone exists for."
jj new
```

---

## Task 6: The relay carries a reply down to the Mac

**Files:**
- Modify: `worker/src/machine.ts`
- Modify: `worker/src/index.ts`
- Modify: `worker/src/types.ts`
- Test: `worker/src/index.test.ts`

**Interfaces:**
- Consumes: the publisher WebSocket the `MachineDO` already holds.
- Produces: `POST /reply {machine, sessionId, text}` → `{ok: true}` when a publisher was connected, 503 when none was.

- [ ] **Step 1: Add the wire types**

In `worker/src/types.ts`:

```typescript
/** What the phone posts to /reply. */
export interface ReplyBody {
  machine: string;
  sessionId: string;
  text: string;
}

/** What the DO writes down the publisher socket. The `type` discriminator
 *  exists because that socket previously carried only snapshots in the other
 *  direction; Canopy must be able to tell a reply from anything added later. */
export interface ReplyEnvelope {
  type: "reply";
  sessionId: string;
  text: string;
}
```

- [ ] **Step 2: Write the failing test**

```typescript
it("reply is refused when no publisher is connected", async () => {
  const res = await SELF.fetch("https://x/reply", {
    method: "POST",
    headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ machine: "no-such-mac", sessionId: "s1", text: "hi" }),
  });
  expect(res.status).toBe(503);
});

it("reply rejects empty text", async () => {
  const res = await SELF.fetch("https://x/reply", {
    method: "POST",
    headers: { Authorization: "Bearer test-secret", "Content-Type": "application/json" },
    body: JSON.stringify({ machine: "m1", sessionId: "s1", text: "   " }),
  });
  expect(res.status).toBe(400);
});
```

- [ ] **Step 3: Run and watch them fail**

Run: `cd worker && npx vitest run`
Expected: two failures, both 404.

- [ ] **Step 4: Deliver in the DO**

In `worker/src/machine.ts`, add to `MachineDO`:

```typescript
/** Writes a reply down the publisher socket, if one is connected.
 *
 *  Uses the sockets the Hibernation API hands back rather than any in-memory
 *  set: this DO may have hibernated since the publisher connected, and an
 *  in-memory list would be empty. The role comes from the attachment for the
 *  same reason. */
deliverReply(envelope: ReplyEnvelope): boolean {
  const publishers = this.ctx.getWebSockets().filter((ws) => {
    const attachment = ws.deserializeAttachment() as { role?: string } | null;
    return attachment?.role === "publisher";
  });
  if (publishers.length === 0) return false;
  const text = JSON.stringify(envelope);
  let delivered = false;
  for (const ws of publishers) {
    try {
      ws.send(text);
      delivered = true;
    } catch {
      // A socket the runtime has not yet reaped. Try the next one rather
      // than reporting failure while another publisher may still be live.
    }
  }
  return delivered;
}
```

Route it in `fetch`, ahead of the `Upgrade` check:

```typescript
if (url.pathname === "/reply" && request.method === "POST") {
  const envelope = (await request.json()) as ReplyEnvelope;
  const ok = this.deliverReply(envelope);
  return new Response(JSON.stringify({ ok }), {
    status: ok ? 200 : 503,
    headers: { "Content-Type": "application/json" },
  });
}
```

- [ ] **Step 5: Route it in the Worker**

In `worker/src/index.ts`, inside the authorized block:

```typescript
if (url.pathname === "/reply" && request.method === "POST") {
  const body = await request.json<ReplyBody>().catch(() => null);
  if (!body?.machine || !body.sessionId) return json({ error: "machine and sessionId required" }, 400);
  const text = (body.text ?? "").trim();
  // An empty reply would inject a blank user turn into a real conversation
  // and permanently into its transcript. Refuse rather than normalize.
  if (!text) return json({ error: "text required" }, 400);
  const stub = env.MACHINE.get(env.MACHINE.idFromName(`mac:${body.machine}`));
  return stub.fetch(new Request("https://do/reply", {
    method: "POST",
    body: JSON.stringify({ type: "reply", sessionId: body.sessionId, text }),
  }));
}
```

- [ ] **Step 6: Run the tests and deploy**

```bash
cd worker && npx vitest run && npx tsc --noEmit && npx wrangler deploy
```
Expected: all tests pass, tsc clean, deploy prints the worker URL.

- [ ] **Step 7: Commit**

```bash
git add worker/src/machine.ts worker/src/index.ts worker/src/types.ts worker/src/index.test.ts
git commit -m "Carry a reply down the publisher socket

Canopy already dials out and holds that socket, so a reply needs no
inbound port on the Mac and no polling. Publishers are found through
ctx.getWebSockets() and the serialized attachment, not an in-memory set,
because the DO may have hibernated since the publisher connected."
```

---

## Task 7: Canopy receives a reply and injects it

**Files:**
- Create: `Sources/Canopy/Roster/RosterReply.swift`
- Modify: `Sources/Canopy/Roster/RosterPublisher.swift`
- Modify: `Sources/Canopy/ShimProcess.swift` (beside `requestKeepAlive` at ~640)
- Modify: `Sources/Canopy/_SidebarLogicProbe.swift`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `ReplyEnvelope` from Task 6.
- Produces: `ShimProcess.requestPhoneReply(text:) -> Bool`.

- [ ] **Step 1: Write the envelope and the routing decision**

Create `Sources/Canopy/Roster/RosterReply.swift`:

```swift
import Foundation

/// A reply typed on the phone, arriving down the publisher socket.
struct ReplyEnvelope: Codable {
    let type: String
    let sessionId: String
    let text: String
}

enum RosterReply {
    /// Which open session an envelope addresses, or nil.
    ///
    /// Matched on `OpenSession.ID`, which is minted per process — the roster
    /// republishes on every state change, so the phone's ids are always from
    /// the current launch. An id from a previous launch therefore finds
    /// nothing, which is the correct outcome: injecting into "some session"
    /// because the intended one is gone would put words in the wrong
    /// conversation, permanently.
    static func target(for envelope: ReplyEnvelope,
                       in sessions: [OpenSession]) -> OpenSession? {
        guard envelope.type == "reply",
              !envelope.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let id = UUID(uuidString: envelope.sessionId)
        else { return nil }
        return sessions.first { $0.id == id }
    }
}
```

- [ ] **Step 2: Write the failing probe assertions**

In `_SidebarLogicProbe.swift`, inside `runAllTests()`:

```swift
// --- roster reply routing
do {
    let a = OpenSession(
        origin: .local(cwd),
        resumeId: "reply-A",
        title: "Reply A",
        project: "ProjectA",
        status: .live,
        lastActiveAt: now
    )
    let good = ReplyEnvelope(type: "reply", sessionId: a.id.uuidString, text: "do the thing")
    check("roster reply: routes to the addressed session",
          RosterReply.target(for: good, in: [a])?.id == a.id)

    let blank = ReplyEnvelope(type: "reply", sessionId: a.id.uuidString, text: "   ")
    check("roster reply: refuses whitespace-only text",
          RosterReply.target(for: blank, in: [a]) == nil)

    let wrongType = ReplyEnvelope(type: "snapshot", sessionId: a.id.uuidString, text: "x")
    check("roster reply: refuses a non-reply envelope",
          RosterReply.target(for: wrongType, in: [a]) == nil)

    let stale = ReplyEnvelope(type: "reply", sessionId: UUID().uuidString, text: "x")
    check("roster reply: an id from a previous launch matches nothing",
          RosterReply.target(for: stale, in: [a]) == nil)
}
```

- [ ] **Step 3: Run the probe and watch it fail**

Run: `./scripts/build_debug_stable.sh` — expected: FAILS to compile, `cannot find 'RosterReply' in scope`, until Step 1's file is in the target. If it compiles, `xcodegen generate` did not pick the new file up; run it explicitly.

- [ ] **Step 4: Receive on the publisher socket**

In `RosterPublisher`, add a receive loop armed right after `task.resume()` in `connectIfConfigured()`:

```swift
/// Called with each reply that arrives down the publisher socket. Set by
/// `AppDelegate` at start, because the publisher owns the connection but
/// not the sessions.
var onReply: ((ReplyEnvelope) -> Void)?

private func receiveReplies(on task: URLSessionWebSocketTask) {
    task.receive { [weak self] result in
        guard case .success(let message) = result else {
            // A failure ends this loop only. `publish()` reconnects on the
            // next state change, and re-arms the loop with the new task, so
            // there is deliberately no retry here.
            return
        }
        if case .string(let text) = message,
           let data = text.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(ReplyEnvelope.self, from: data) {
            Task { @MainActor in self?.onReply?(envelope) }
        }
        Task { @MainActor in
            guard let self, self.task === task else { return }
            self.receiveReplies(on: task)
        }
    }
}
```

and call `receiveReplies(on: task)` immediately after `task.resume()`.

- [ ] **Step 5: Inject the reply**

In `ShimProcess`, beside `requestKeepAlive`:

```swift
/// Injects a reply typed on the phone as a real user turn.
///
/// Reuses `requestKeepAlive`'s busy-shim guard — never its swallow latches.
/// A keep-alive hides itself on purpose; a reply is the opposite and must
/// appear in the transcript and the replay exactly as if it had been typed
/// at this Mac, or the user cannot see what they told the session to do.
///
/// Returns whether it was injected, so the caller can log a refusal rather
/// than leave the phone believing a message landed.
@discardableResult
func requestPhoneReply(text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    guard !keepAliveInFlight, !recapRequestInFlight, !isWorking,
          pendingPermissionRequestIds.isEmpty, !lastAssistantHadAskUserQuestion
    else {
        logger.notice("roster reply refused: \(self.ineligibilityReasonForReply(), privacy: .public)")
        return false
    }
    // The same envelope `requestKeepAlive` sends, with the phone's text.
    // `origin: ["kind": "human"]` is correct and load-bearing here: a reply
    // IS a human's input, arriving by a different route, and the CLI records
    // it as one.
    sendToShim([
        "type": "webview_message",
        "message": [
            "type": "io_message",
            "channelId": channelId,
            "done": false,
            "message": [
                "type": "user",
                "session_id": "",
                "origin": ["kind": "human"] as [String: Any],
                "parent_tool_use_id": NSNull(),
                "uuid": UUID().uuidString.lowercased(),
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": trimmed]],
                ] as [String: Any],
            ] as [String: Any],
        ] as [String: Any],
    ])
    return true
}
```

Add a one-line `ineligibilityReasonForReply()` mirroring the existing `keepAliveIneligibilityReason`.

Wire the closure in `AppDelegate.startRosterPublisher`, after `publisher.start()`:

```swift
publisher.onReply = { [weak store] envelope in
    guard let store,
          let session = RosterReply.target(for: envelope, in: store.openSessions),
          let shim = session.shim
    else { return }
    shim.requestPhoneReply(text: envelope.text)
}
```

- [ ] **Step 6: Run the probe and raise the floor**

```bash
./scripts/build_debug_stable.sh
CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy | tail -1
```
Expected: `--- N passed, 0 failed ---` with N four higher than before. Write **that measured N** into `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml`; never compute it by addition.

- [ ] **Step 7: Commit**

```bash
jj describe -r @ -m "Inject a reply from the phone as a real user turn

Arrives down the publisher socket Canopy already holds. Reuses
requestKeepAlive's busy-shim guard and none of its swallow latches: a
keep-alive hides itself on purpose, a reply must be visible in the
transcript and the replay exactly as if typed at the Mac.

A session id from a previous launch matches nothing, deliberately —
injecting into some other session because the intended one is gone would
put words in the wrong conversation, permanently."
jj new
```

---

## Task 8: The phone composes a reply

**Files:**
- Create: `Sources/ReplySheet.swift`
- Modify: `Sources/RosterClient.swift`
- Modify: `Sources/CanopyMobileApp.swift`

**Interfaces:**
- Consumes: `POST /reply` from Task 6.
- Produces: a sheet reachable by tapping a roster row and by tapping a notification.

- [ ] **Step 1: Add the client call**

In `Sources/RosterClient.swift`:

```swift
/// Sends a reply. Throws `RosterError.unexpectedStatus(503)` when no Mac is
/// connected — a distinguishable case, because "your Mac is asleep" is a
/// different thing for the user to do about than "that failed".
func sendReply(machine: String, sessionId: String, text: String) async throws {
    var request = URLRequest(url: baseURL.appendingPathComponent("reply"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "machine": machine, "sessionId": sessionId, "text": text,
    ])
    let (_, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    switch status {
    case 200: return
    case 401: throw RosterError.unauthorized
    default: throw RosterError.unexpectedStatus(status)
    }
}
```

- [ ] **Step 2: Write the sheet**

Create `Sources/ReplySheet.swift`:

```swift
import SwiftUI

/// Free text to one session. Deliberately not a chat: this app shows no
/// transcript, so a thread here would imply a history it cannot render.
struct ReplySheet: View {
    let machine: String
    let sessionId: String
    let sessionTitle: String
    let send: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(sessionTitle) {
                    TextField("What should it do next?", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await submit() } }
                        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        do {
            try await send(text.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch let e as RosterError {
            error = e.message
        } catch {
            error = error.localizedDescription
        }
    }
}
```

- [ ] **Step 3: Present it from a row and from a notification**

In `CanopyMobileApp.swift`, add state and a tap target on each pane row:

```swift
@State private var replyTarget: (machine: String, pane: PaneRow)?
```

Give each rendered row `.onTapGesture { replyTarget = (machineId, pane) }`, and attach:

```swift
.sheet(item: Binding(
    get: { replyTarget.map { ReplyTargetBox(machine: $0.machine, pane: $0.pane) } },
    set: { if $0 == nil { replyTarget = nil } }
)) { box in
    ReplySheet(machine: box.machine,
               sessionId: box.pane.sessionId,
               sessionTitle: box.pane.title) { text in
        guard let client else { throw RosterError.unexpectedStatus(-1) }
        try await client.sendReply(machine: box.machine, sessionId: box.pane.sessionId, text: text)
    }
}
```

with the small identifiable box:

```swift
private struct ReplyTargetBox: Identifiable {
    let machine: String
    let pane: PaneRow
    var id: String { machine + "/" + pane.sessionId }
}
```

For the notification tap, implement `userNotificationCenter(_:didReceive:withCompletionHandler:)` on `PushRegistrar`, read `machine` and `sessionId` out of `response.notification.request.content.userInfo`, and post them through `NotificationCenter.default` to a `.onReceive` in the App that sets `replyTarget`. The push payload from Task 3 already carries both.

- [ ] **Step 4: Verify end to end on the real phone**

Build and install as in Task 4. Then, with a Canopy session open and idle:
1. Tap its row on the phone, type `say hello and nothing else`, Send.
2. Watch the Mac: that text must appear in the session as an ordinary user turn and get a reply.
3. Quit and reopen the session in Canopy and confirm the reply is still in the replayed transcript — it must NOT be filtered out the way a keep-alive is.

Then verify the refusal path: start a long turn, and while it is running send another reply. Expected: the Mac logs `roster reply refused: …` and injects nothing.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReplySheet.swift Sources/RosterClient.swift Sources/CanopyMobileApp.swift
git commit -m "Reply to a session from the phone

Deliberately not a chat: this app renders no transcript, so a thread here
would imply a history it cannot show. A 503 is surfaced distinctly because
'your Mac is asleep' is a different thing for the user to act on than
'that failed'."
```

---

## Verification of the whole feature

- [ ] One event buzzes once: with the phone app installed and Pager also installed, finish a turn in a Canopy session and confirm **only** Canopy Mobile buzzes. Then finish a turn in a terminal `claude` session and confirm **only** Pager does.
- [ ] `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy` reports `0 failed`, and `EXPECTED_ASSERTIONS` in `ci.yml` equals the measured count.
- [ ] `cd worker && npx vitest run && npx tsc --noEmit` is clean, and `EXPECTED_TESTS` matches.
- [ ] A reply sent while the Mac is asleep returns 503 and the phone says so, rather than reporting success.

## Two deliberate deviations from the spec

- **The spec says the notification "can carry the pane index"; this plan does not send one.** That sentence argues why Canopy must send the notification rather than a hook — Canopy knows things a hook cannot. The thing the reply actually needs from that set is the session id, which is sent. A pane index would only decorate the banner, and it goes stale the moment a pane closes, so it is left out rather than sent and quietly wrong.
- **The spec says the reply's mapping "stays server-side in KV"; this plan puts `machine` and `sessionId` in the push payload.** That instruction exists to respect the APNs 4 KB limit by keeping conversation text out of the payload. Two short identifiers are not conversation text — they cost well under a hundred bytes — and a KV round trip would add a failure mode (an expired key) to a path that has none. The text itself still never rides in a push.

## Known limits, accepted

- **A reply can only reach a session that has a live shim.** A closed or `.dormant` row cannot be injected into; the phone will get a 503-shaped refusal via `requestPhoneReply` returning false. Waking a session from the phone is a separate feature.
- **No delivery receipt.** `/reply` returns 200 once the DO wrote to the socket, which is not the same as the shim accepting it — `requestPhoneReply` can still refuse for a busy session. Closing that gap needs an ack back up the socket and is deliberately not in this plan.
- **One device token.** `device_token` is a single KV key, exactly as Pager's is. A second phone would overwrite the first.
