# Canopy Mobile — Roster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Canopy pane on every Mac, visible on a phone, updating live while the app is open.

**Architecture:** Each Mac's Canopy dials out to a Cloudflare Durable Object named for that Mac and pushes a snapshot of its panes whenever the state changes. A Worker fans those in and serves them to the phone, which holds a WebSocket only while foregrounded. No inbound port on any Mac, and no conversation content leaves it.

**Tech Stack:** Swift 6 / SwiftUI (Canopy, macOS 15+), Cloudflare Workers + Durable Objects with the WebSocket Hibernation API (TypeScript), SwiftUI (iOS app).

**Spec:** `docs/superpowers/specs/2026-09-03-canopy-mobile-design.md`

**Scope:** Build-order steps 1-3 of that spec — the roster. Steps 4-5 (Canopy-originated notifications, and reply) are a separate plan, as the spec requires. Nothing in this plan sends a notification or injects a prompt.

## Global Constraints

- **The roster carries no conversation content.** Six activity states, titles, project/branch, context %, model, message count, quota, time-in-state. Nothing else. A current-tool tracker is a documented extension point and is not in this plan.
- **`state.acceptWebSocket(ws)`, never `ws.accept()`.** Hibernation is the difference between free and billing up to 15 minutes per idle connection.
- **Durable Objects must be SQLite-backed** (`new_sqlite_classes` in the migration) — that is the only kind available on the Workers Free plan.
- **Stable machine id is `IOPlatformUUID`**, never the hostname. Display name is a separate field.
- **Auth is `Authorization: Bearer <SHARED_SECRET>`**, matching Pager's Worker.
- **Canopy has no XCTest.** Pure logic is asserted in `Sources/Canopy/_SidebarLogicProbe.swift`, run as `CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy`, and gated by `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml`. **Every task that adds probe assertions must raise that floor to the number the probe actually reports** — read it off a run, never compute it.
- **Canopy needs an Xcode 26 toolchain.** Build with `./scripts/build_debug_stable.sh`.
- **Canopy is jj-colocated.** Never `git checkout -- <path>` to revert a file; HEAD is detached at main and that restores main's copy.
- New repo: `~/repos/Personal/Canopy-Mobile`, laid out like Pager — `worker/` and `Sources/`.

---

## File Structure

**`~/repos/Personal/Canopy-Mobile/` (new repo)**

| File | Responsibility |
|---|---|
| `worker/wrangler.toml` | Worker config: DO binding, SQLite migration, current `compatibility_date` |
| `worker/src/index.ts` | HTTP routing and auth only. Delegates to the DO. |
| `worker/src/machine.ts` | The `MachineDO` class: holds one Mac's roster, accepts both sockets |
| `worker/src/types.ts` | The wire types, shared by the Worker and mirrored in Swift |
| `worker/src/*.test.ts` | vitest, via `@cloudflare/vitest-pool-workers` |
| `Sources/…` | The iOS app (Task 6 onward) |

**`~/repos/Personal/Canopy/` (existing)**

| File | Responsibility |
|---|---|
| `Sources/Canopy/Roster/RosterSnapshot.swift` | Pure value types + JSON encoding of what a Mac publishes |
| `Sources/Canopy/Roster/MachineIdentity.swift` | Stable id and display name |
| `Sources/Canopy/Roster/RosterPublisher.swift` | Observation tracking, connection, send-on-change |
| `Sources/Canopy/CanopySettings.swift` | +`machineDisplayName`, +`rosterEnabled`, +`rosterEndpoint` |
| `Sources/Canopy/SettingsView.swift` | The three new controls |
| `Sources/Canopy/_SidebarLogicProbe.swift` | Assertions for the two pure types |

The three roster files sit in their own directory for the reason `MacroPad/` does: it is a subsystem with one external entry point, and keeping it out of the top level makes that boundary visible.

---

### Task 1: Worker skeleton with a hibernating Durable Object

This is the uncertain one. Neither the outbound connection nor hibernation has been exercised. If it fights back, stop and revisit the design before building anything else.

**Files:**
- Create: `~/repos/Personal/Canopy-Mobile/worker/package.json`
- Create: `~/repos/Personal/Canopy-Mobile/worker/wrangler.toml`
- Create: `~/repos/Personal/Canopy-Mobile/worker/tsconfig.json`
- Create: `~/repos/Personal/Canopy-Mobile/worker/vitest.config.ts`
- Create: `~/repos/Personal/Canopy-Mobile/worker/src/types.ts`
- Create: `~/repos/Personal/Canopy-Mobile/worker/src/machine.ts`
- Create: `~/repos/Personal/Canopy-Mobile/worker/src/index.ts`
- Test: `~/repos/Personal/Canopy-Mobile/worker/src/machine.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `MachineDO` (exported class, DO binding `MACHINE`); route `GET /publish?machine=<id>` upgrading to a WebSocket; wire types `PaneRow`, `MachineSnapshot`.

- [ ] **Step 1: Create the repo and the Worker directory**

```bash
mkdir -p ~/repos/Personal/Canopy-Mobile/worker/src
cd ~/repos/Personal/Canopy-Mobile
git init
printf 'node_modules/\n.wrangler/\nbuild/\n.DS_Store\n' > .gitignore
```

- [ ] **Step 2: Write `worker/package.json`**

```json
{
  "name": "canopy-mobile-relay",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "test": "vitest run"
  },
  "devDependencies": {
    "@cloudflare/vitest-pool-workers": "^0.8.0",
    "@cloudflare/workers-types": "^4.20260409.1",
    "typescript": "^6.0.2",
    "vitest": "^4.1.5",
    "wrangler": "^4"
  }
}
```

- [ ] **Step 3: Write `worker/wrangler.toml`**

`new_sqlite_classes` is required — a key-value-backed DO is not available on the Free plan. Set `compatibility_date` to today's date, not Pager's `2024-12-01`.

```toml
name = "canopy-mobile-relay"
main = "src/index.ts"
compatibility_date = "2026-09-03"

[observability]
enabled = true
head_sampling_rate = 1.0

[[durable_objects.bindings]]
name = "MACHINE"
class_name = "MachineDO"

[[migrations]]
tag = "v1"
new_sqlite_classes = ["MachineDO"]
```

- [ ] **Step 4: Write `worker/tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "es2022",
    "module": "es2022",
    "moduleResolution": "bundler",
    "lib": ["es2022"],
    "types": ["@cloudflare/workers-types"],
    "strict": true,
    "noEmit": true
  },
  "include": ["src/**/*.ts"]
}
```

- [ ] **Step 5: Write `worker/vitest.config.ts`**

The pool is what gives the test a real DO; plain vitest cannot construct one.

```typescript
import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

export default defineWorkersConfig({
  test: {
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
      },
    },
  },
});
```

- [ ] **Step 6: Write `worker/src/types.ts`**

```typescript
/** One pane on one Mac. Mirrors RosterSnapshot.Pane in the Canopy repo. */
export interface PaneRow {
  /** OpenSession.ID as a UUID string. Stable for the life of the process. */
  sessionId: string;
  /** 0-based position in the pane strip. */
  paneIndex: number;
  title: string;
  /** "repo · branch", already composed by Canopy. */
  project: string;
  /** One of SessionActivity's six cases, lowercased. */
  state: string;
  /** Unix seconds at which the pane entered `state`. */
  stateSince: number;
  contextPct: number;
  model: string;
  messageCount: number;
}

export interface MachineSnapshot {
  /** IOPlatformUUID. Never the hostname. */
  machineId: string;
  displayName: string;
  /** Unix seconds when Canopy composed this snapshot. */
  publishedAt: number;
  sessionPct: number;
  weeklyPct: number;
  panes: PaneRow[];
}
```

- [ ] **Step 7: Write the failing test**

```typescript
// worker/src/machine.test.ts
import { env, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import type { MachineSnapshot } from "./types";

const snapshot: MachineSnapshot = {
  machineId: "AAAA-1111",
  displayName: "Mac Studio",
  publishedAt: 1_700_000_000,
  sessionPct: 43,
  weeklyPct: 25,
  panes: [
    {
      sessionId: "s1", paneIndex: 0, title: "Canopy Mobile",
      project: "Canopy · main", state: "asking", stateSince: 1_699_999_000,
      contextPct: 17, model: "opus", messageCount: 42,
    },
  ],
};

describe("MachineDO", () => {
  it("stores a published snapshot and reads it back", async () => {
    const id = env.MACHINE.idFromName("mac:AAAA-1111");
    const stub = env.MACHINE.get(id);
    await runInDurableObject(stub, async (instance: any) => {
      instance.applySnapshot(snapshot);
      expect(instance.currentSnapshot()?.displayName).toBe("Mac Studio");
      expect(instance.currentSnapshot()?.panes[0].state).toBe("asking");
    });
  });

  it("survives losing its in-memory state", async () => {
    const id = env.MACHINE.idFromName("mac:BBBB-2222");
    const stub = env.MACHINE.get(id);
    await runInDurableObject(stub, async (instance: any) => {
      instance.applySnapshot({ ...snapshot, machineId: "BBBB-2222" });
    });
    // A fresh instance handle reads from SQLite, not from memory.
    await runInDurableObject(stub, async (instance: any) => {
      instance.forgetInMemoryState();
      expect(instance.currentSnapshot()?.machineId).toBe("BBBB-2222");
    });
  });
});
```

- [ ] **Step 8: Run the test to verify it fails**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npm install && npm test
```

Expected: FAIL — `MachineDO` is not exported / `applySnapshot` is not a function.

- [ ] **Step 9: Write `worker/src/machine.ts`**

The snapshot is written to SQLite on every apply, because hibernation clears the in-memory copy. `acceptWebSocket` is what makes an idle publisher free.

```typescript
import { DurableObject } from "cloudflare:workers";
import type { MachineSnapshot } from "./types";

export class MachineDO extends DurableObject {
  private cached: MachineSnapshot | null = null;

  constructor(ctx: DurableObjectState, env: unknown) {
    super(ctx as any, env as any);
    ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(
        `CREATE TABLE IF NOT EXISTS snapshot (id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT NOT NULL)`
      );
    });
  }

  /**
   * Replace the whole roster for this Mac. Canopy always sends a full snapshot.
   *
   * The spec requires anything undelivered to be queued in SQLite, because
   * hibernation clears memory. A roster has nothing to queue: the newest
   * snapshot is the whole truth and supersedes every earlier one, so storing
   * the latest IS the queue. Do not add a message log here — a replayed older
   * snapshot would resurrect a pane that has since closed.
   */
  applySnapshot(snapshot: MachineSnapshot): void {
    this.cached = snapshot;
    this.ctx.storage.sql.exec(
      `INSERT INTO snapshot (id, json) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json`,
      JSON.stringify(snapshot)
    );
  }

  currentSnapshot(): MachineSnapshot | null {
    if (this.cached) return this.cached;
    const rows = this.ctx.storage.sql
      .exec<{ json: string }>(`SELECT json FROM snapshot WHERE id = 1`)
      .toArray();
    if (rows.length === 0) return null;
    this.cached = JSON.parse(rows[0].json) as MachineSnapshot;
    return this.cached;
  }

  /** Test seam: simulate what hibernation does to the in-memory copy. */
  forgetInMemoryState(): void {
    this.cached = null;
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const pair = new WebSocketPair();
    // Hibernation API. `pair[1].accept()` would bill an idle connection.
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  webSocketMessage(_ws: WebSocket, message: string | ArrayBuffer): void {
    if (typeof message !== "string") return;
    const parsed = JSON.parse(message) as MachineSnapshot;
    this.applySnapshot(parsed);
  }
}
```

- [ ] **Step 10: Write `worker/src/index.ts`**

```typescript
import { MachineDO } from "./machine";
export { MachineDO };

interface Env {
  MACHINE: DurableObjectNamespace;
  SHARED_SECRET: string;
}

function authorized(request: Request, env: Env): boolean {
  return request.headers.get("Authorization") === `Bearer ${env.SHARED_SECRET}`;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (!authorized(request, env)) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }
    if (url.pathname === "/publish") {
      const machine = url.searchParams.get("machine");
      if (!machine) return new Response("machine required", { status: 400 });
      const stub = env.MACHINE.get(env.MACHINE.idFromName(`mac:${machine}`));
      return stub.fetch(request);
    }
    return new Response("not found", { status: 404 });
  },
};
```

- [ ] **Step 11: Run the tests to verify they pass**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npm test
```

Expected: PASS, 2 tests.

- [ ] **Step 12: Deploy and prove hibernation on the real edge**

The test uses a simulated hibernation. This step exercises the real one.

```bash
cd ~/repos/Personal/Canopy-Mobile/worker
npx wrangler secret put SHARED_SECRET   # paste the same value Pager uses
npx wrangler deploy
```

- [ ] **Step 13: Commit**

```bash
cd ~/repos/Personal/Canopy-Mobile
git add -A
git commit -m "feat: Worker with a hibernating per-Mac Durable Object"
```

---

### Task 2: Canopy composes a roster snapshot

Pure value types and encoding, with no networking. This is what the probe can assert.

**Files:**
- Create: `~/repos/Personal/Canopy/Sources/Canopy/Roster/RosterSnapshot.swift`
- Modify: `~/repos/Personal/Canopy/Sources/Canopy/_SidebarLogicProbe.swift`
- Modify: `~/repos/Personal/Canopy/.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `SessionActivity` (`CaseIterable`, `label: String`), `OpenSession`, `PaneSlot`, `PaneContent`.
- Produces: `RosterSnapshot` (`Codable`), `RosterSnapshot.Pane`, and `RosterSnapshot.wireState(for:) -> String`.

- [ ] **Step 1: Write the failing probe assertions**

Add to `_SidebarLogicProbe.swift`, inside `runAllTests()`, after the existing relocation block:

```swift
// Roster wire encoding. The six activity states are a contract with the
// phone: renaming a case silently changes what the roster renders, and
// nothing else in this repo would notice.
record("roster: every activity state has a distinct wire name",
       Set(SessionActivity.allCases.map(RosterSnapshot.wireState(for:))).count
           == SessionActivity.allCases.count)
record("roster: wire names are lowercase and stable",
       RosterSnapshot.wireState(for: .asking) == "asking"
           && RosterSnapshot.wireState(for: .background) == "background")

// A launcher pane has no session, so it must not produce a row — the phone
// would render a nameless entry it can never act on.
let rosterPanes = [
    PaneSlot(content: .launcher, preferredWidth: 100),
    PaneSlot(content: .session(UUID()), preferredWidth: 100),
]
record("roster: a launcher pane yields no row",
       RosterSnapshot.paneIndexes(in: rosterPanes).count == 1)
record("roster: the index is the pane's position, not the row's",
       RosterSnapshot.paneIndexes(in: rosterPanes).first?.value == 1)

// JSON round-trip: the phone decodes this, so a key rename is a break.
let rosterFixture = RosterSnapshot(
    machineId: "AAAA-1111", displayName: "Mac Studio",
    publishedAt: 1_700_000_000, sessionPct: 43, weeklyPct: 25,
    panes: [RosterSnapshot.Pane(
        sessionId: "s1", paneIndex: 0, title: "T", project: "P · main",
        state: "asking", stateSince: 1_699_999_000,
        contextPct: 17, model: "opus", messageCount: 42)])
let rosterJSON = (try? JSONEncoder().encode(rosterFixture)).flatMap {
    String(data: $0, encoding: .utf8)
} ?? ""
record("roster: JSON carries the keys the phone reads",
       rosterJSON.contains("\"machineId\"") && rosterJSON.contains("\"stateSince\"")
           && rosterJSON.contains("\"paneIndex\""),
       "got \(rosterJSON.prefix(120))")
record("roster: JSON round-trips",
       (try? JSONDecoder().decode(
           RosterSnapshot.self, from: Data(rosterJSON.utf8)))?.panes.first?.state == "asking")
```

- [ ] **Step 2: Run the probe to verify it fails**

```bash
cd ~/repos/Personal/Canopy && ./scripts/build_debug_stable.sh
```

Expected: BUILD FAILS — `cannot find 'RosterSnapshot' in scope`.

- [ ] **Step 3: Write `Sources/Canopy/Roster/RosterSnapshot.swift`**

```swift
import Foundation

/// What one Mac publishes about itself. A full snapshot every time — the
/// Durable Object replaces rather than merges, so a dropped update can never
/// leave the phone showing a pane that has since closed.
///
/// **Carries no conversation content**, and that is a contract, not an
/// oversight: see the spec's roster section. Adding a field that quotes the
/// transcript reopens a decision that was made deliberately.
struct RosterSnapshot: Codable, Equatable {
    struct Pane: Codable, Equatable {
        let sessionId: String
        let paneIndex: Int
        let title: String
        let project: String
        let state: String
        let stateSince: Int
        let contextPct: Int
        let model: String
        let messageCount: Int
    }

    let machineId: String
    let displayName: String
    let publishedAt: Int
    let sessionPct: Int
    let weeklyPct: Int
    let panes: [Pane]

    /// The wire name for an activity state.
    ///
    /// Deliberately a `switch` rather than a raw value on `SessionActivity`:
    /// that enum belongs to the sidebar and the MacroPad, and giving it a
    /// wire representation would let a rename there change what the phone
    /// renders. The mapping lives here, where the probe pins it.
    static func wireState(for activity: SessionActivity) -> String {
        switch activity {
        case .idle: return "idle"
        case .working: return "working"
        case .background: return "background"
        case .asking: return "asking"
        case .unread: return "unread"
        case .error: return "error"
        }
    }

    /// Session id → pane index, for the panes that hold a session.
    ///
    /// A launcher pane is skipped, and the index kept is its position in the
    /// STRIP — so a launcher sitting to the left does not renumber the panes
    /// after it. The phone's row order and Canopy's Cmd+1..9 then agree.
    static func paneIndexes(in panes: [PaneSlot]) -> [OpenSession.ID: Int] {
        var result: [OpenSession.ID: Int] = [:]
        for (index, slot) in panes.enumerated() {
            if case .session(let id) = slot.content { result[id] = index }
        }
        return result
    }
}
```

- [ ] **Step 4: Run the probe and read the new count**

```bash
cd ~/repos/Personal/Canopy && ./scripts/build_debug_stable.sh \
  && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -1
```

Expected: `--- N passed, 0 failed ---` with N six higher than the current floor.

- [ ] **Step 5: Raise the CI floor to the number the probe reported**

Edit `EXPECTED_ASSERTIONS` in `.github/workflows/ci.yml` to exactly the N from Step 4. Do not compute it by addition — the spec's own rule.

- [ ] **Step 6: Mutation-test one assertion**

Change `case .asking: return "asking"` to `return "idle"`, rebuild, run the probe. Expected: the distinct-wire-names assertion fails. Restore with `cp` from a backup, **not** `git checkout` — this repo is jj-colocated.

- [ ] **Step 7: Commit**

```bash
cd ~/repos/Personal/Canopy
jj describe -r @ -m "Add the roster snapshot Canopy publishes about itself

Pure value types and the activity-state wire mapping, with the mapping
kept out of SessionActivity so a rename there cannot silently change what
the phone renders. Six probe assertions; floor raised to the measured count."
jj new
```

---

### Task 3: Canopy identifies its Mac

**Files:**
- Create: `~/repos/Personal/Canopy/Sources/Canopy/Roster/MachineIdentity.swift`
- Modify: `~/repos/Personal/Canopy/Sources/Canopy/CanopySettings.swift`
- Modify: `~/repos/Personal/Canopy/Sources/Canopy/SettingsView.swift`
- Modify: `~/repos/Personal/Canopy/Sources/Canopy/_SidebarLogicProbe.swift`
- Modify: `~/repos/Personal/Canopy/.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `CanopySettings`.
- Produces: `MachineIdentity.stableId() -> String?`, `MachineIdentity.defaultDisplayName() -> String`, `MachineIdentity.resolvedDisplayName(setting:fallback:) -> String`; `CanopySettings.machineDisplayName`, `.rosterEnabled`, `.rosterEndpoint`.

- [ ] **Step 1: Write the failing probe assertions**

```swift
// The display name falls back rather than going blank: an empty Settings
// field must not publish an unnamed Mac to a roster whose whole job is
// telling two Macs apart.
record("machine: a set display name wins",
       MachineIdentity.resolvedDisplayName(setting: "Studio", fallback: "host") == "Studio")
record("machine: an empty setting falls back",
       MachineIdentity.resolvedDisplayName(setting: "", fallback: "host") == "host")
record("machine: a whitespace-only setting falls back",
       MachineIdentity.resolvedDisplayName(setting: "   ", fallback: "host") == "host")
record("machine: a set name is trimmed",
       MachineIdentity.resolvedDisplayName(setting: "  Studio  ", fallback: "host") == "Studio")
// The id is what getByName keys on. A blank one would collide every Mac
// into one Durable Object.
record("machine: the stable id is a UUID of the documented length",
       (MachineIdentity.stableId()?.count ?? 0) == 36)
```

- [ ] **Step 2: Run the probe to verify it fails**

```bash
cd ~/repos/Personal/Canopy && ./scripts/build_debug_stable.sh
```

Expected: BUILD FAILS — `cannot find 'MachineIdentity' in scope`.

- [ ] **Step 3: Write `Sources/Canopy/Roster/MachineIdentity.swift`**

```swift
import Foundation
import IOKit
import os.log

/// Who this Mac is, to the roster.
///
/// Two fields, deliberately separate. The **id** keys the Durable Object and
/// every match; the **display name** is only ever rendered. Keeping them apart
/// is what makes renaming free — the id never moves, so a rename breaks no
/// pane and no pending notification.
enum MachineIdentity {
    private static let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "MachineIdentity")

    /// `IOPlatformUUID` — stable across renames, network changes and OS
    /// reinstalls. The hostname was rejected because it moves with the
    /// network, which is the one thing the id must not do.
    static func stableId() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else {
            logger.error("IOPlatformExpertDevice not found; roster cannot identify this Mac")
            return nil
        }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    /// `scutil --get ComputerName`, which is what the user already sees in
    /// System Settings.
    static func defaultDisplayName() -> String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "Mac" : name
    }

    /// Pure so the probe can pin the fallback. A blank setting must never
    /// publish an unnamed Mac — the roster's whole job is telling Macs apart.
    static func resolvedDisplayName(setting: String, fallback: String) -> String {
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
```

- [ ] **Step 4: Add the three settings**

In `CanopySettings.swift`, alongside the existing `macroPad*` properties and following their `didSet { save() }` pattern exactly:

```swift
    /// Shown in the phone's roster and, later, in notification text. Empty
    /// means "use the Mac's own name" — see `MachineIdentity`.
    var machineDisplayName: String = "" {
        didSet { save() }
    }

    /// Off by default. Publishing dials out to a third-party endpoint, so it
    /// is opt-in the way `allowDangerouslySkipPermissions` is.
    var rosterEnabled: Bool = false {
        didSet { save() }
    }

    /// The relay's base URL, e.g. `https://canopy-mobile-relay.example.workers.dev`.
    var rosterEndpoint: String = "" {
        didSet { save() }
    }
```

Add the three keys to the same `load()` / `save()` dictionary the neighbouring properties use.

- [ ] **Step 5: Add the Settings controls**

In `SettingsView.swift`, in a new `Section("Mobile")` placed after the MacroPad section:

```swift
Section("Mobile") {
    Toggle("Publish this Mac's panes", isOn: $settings.rosterEnabled)
    TextField("Relay URL", text: $settings.rosterEndpoint)
        .textFieldStyle(.roundedBorder)
        .disabled(!settings.rosterEnabled)
    TextField("This Mac's name", text: $settings.machineDisplayName,
              prompt: Text(MachineIdentity.defaultDisplayName()))
        .textFieldStyle(.roundedBorder)
    SecureField("Relay secret", text: $relaySecret)
        .textFieldStyle(.roundedBorder)
        .onSubmit { MachineIdentity.storeRelaySecret(relaySecret) }
    Text("Shown on the phone. Leave empty to use the Mac's own name. The secret is kept in the Keychain, not in settings.json — that file is plaintext and is shared with the installed Release build.")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

with `@State private var relaySecret = ""` on the view, and in `MachineIdentity`:

```swift
    /// Write the relay secret to the Keychain. Deleting first is what makes
    /// this an upsert — `SecItemAdd` on an existing item fails with
    /// `errSecDuplicateItem` rather than replacing it.
    static func storeRelaySecret(_ secret: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sh.saqoo.Canopy.roster",
            kSecAttrAccount as String: NSUserName(),
        ]
        SecItemDelete(base as CFDictionary)
        guard !secret.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("could not store the relay secret: \(status, privacy: .public)")
        }
    }
```

`MachineIdentity.swift` needs `import Security` for this.

- [ ] **Step 6: Run the probe and raise the floor**

```bash
cd ~/repos/Personal/Canopy && ./scripts/build_debug_stable.sh \
  && CANOPY_RUN_LOGIC_PROBE=1 ./build/Build/Products/Debug/Canopy.app/Contents/MacOS/Canopy 2>&1 | tail -1
```

Set `EXPECTED_ASSERTIONS` to the reported N.

- [ ] **Step 7: Commit**

```bash
cd ~/repos/Personal/Canopy
jj describe -r @ -m "Identify this Mac to the roster, with the name as a setting

IOPlatformUUID keys the Durable Object; the display name is a separate
Settings field defaulting to the Mac's own name. iOS renders a notification
banner from the payload, so the name has to be chosen before the push is
sent — which is why it lives here and not in the app."
jj new
```

---

### Task 4: Canopy publishes on change

**Files:**
- Create: `~/repos/Personal/Canopy/Sources/Canopy/Roster/RosterPublisher.swift`
- Modify: `~/repos/Personal/Canopy/Sources/Canopy/CanopyApp.swift`

**Interfaces:**
- Consumes: `RosterSnapshot`, `MachineIdentity`, `CanopySettings`, `SessionStore`, `SharedRateLimitData`.
- Produces: `RosterPublisher(store:settings:)`, `.start()`, `.stop()`.

- [ ] **Step 1: Write `Sources/Canopy/Roster/RosterPublisher.swift`**

The observation-tracking shape is copied from `MacroPadController.refresh()` — the same problem, already solved once in this codebase. Do not invent a second shape.

```swift
import Foundation
import Observation
import Security
import os.log

/// Publishes this Mac's panes to the relay whenever they change.
///
/// The tracking shape is `MacroPadController`'s: one `withObservationTracking`
/// pass that reads everything the snapshot needs and re-arms itself. That
/// controller is the precedent for turning `SessionActivity` into an output,
/// and a second shape here would be a second thing to keep correct.
///
/// A snapshot is always FULL. The Durable Object replaces rather than merges,
/// so a dropped update cannot leave a closed pane on the phone forever.
@MainActor
final class RosterPublisher {
    private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "Roster")
    private let store: SessionStore
    private let settings: CanopySettings
    private var task: URLSessionWebSocketTask?
    private var stateSince: [OpenSession.ID: Int] = [:]
    private var lastStates: [OpenSession.ID: String] = [:]
    private var running = false

    init(store: SessionStore, settings: CanopySettings) {
        self.store = store
        self.settings = settings
    }

    func start() {
        guard !running else { return }
        running = true
        connectIfConfigured()
        observe()
    }

    func stop() {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func observe() {
        withObservationTracking {
            _ = snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.publish()
                self.observe()
            }
        }
    }

    private func connectIfConfigured() {
        guard settings.rosterEnabled,
              let machineId = MachineIdentity.stableId(),
              var components = URLComponents(string: settings.rosterEndpoint)
        else { return }
        components.path = "/publish"
        components.queryItems = [URLQueryItem(name: "machine", value: machineId)]
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else {
            logger.error("roster endpoint is not a usable URL")
            return
        }
        guard let secret = RosterPublisher.sharedSecret() else {
            // Nothing to authenticate with. Log the decision, never the value.
            logger.notice("roster: no relay secret in the Keychain; not connecting")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        self.task = task
        logger.notice("roster: connected as \(machineId, privacy: .public)")
    }

    /// The relay secret, from the Keychain.
    ///
    /// **Not from the process environment.** Canopy is launched with `open`,
    /// which gives it no shell environment, so an env var would be empty in
    /// every normal launch and present only when a developer runs the binary
    /// from a terminal — working in exactly the case nobody ships. Not from
    /// `settings.json` either: that file is plaintext on disk and is SHARED
    /// with the installed Release build.
    ///
    /// `KeychainAuth` is the precedent for reading a secret in this app; this
    /// item is written by the Settings field in Task 3 and read here.
    private static func sharedSecret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "sh.saqoo.Canopy.roster",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty
        else { return nil }
        return secret
    }

    /// Composes the full snapshot. Reading every property here is what arms
    /// the observation above — a field read only inside `publish()` would not
    /// trigger a re-publish when it changed.
    private func snapshot() -> RosterSnapshot? {
        guard let machineId = MachineIdentity.stableId() else { return nil }
        let indexes = RosterSnapshot.paneIndexes(in: store.panes)
        let now = Int(Date().timeIntervalSince1970)
        var rows: [RosterSnapshot.Pane] = []
        for session in store.openSessions {
            guard let paneIndex = indexes[session.id] else { continue }
            let activity = SessionActivity.of(
                session, isUnread: store.unreadSessionIds.contains(session.id))
            let wire = RosterSnapshot.wireState(for: activity)
            if lastStates[session.id] != wire {
                lastStates[session.id] = wire
                stateSince[session.id] = now
            }
            rows.append(RosterSnapshot.Pane(
                sessionId: session.id.uuidString,
                paneIndex: paneIndex,
                title: session.title,
                project: session.projectLabel,
                state: wire,
                stateSince: stateSince[session.id] ?? now,
                contextPct: session.statusBar.contextPct,
                model: session.statusBar.model,
                messageCount: session.statusBar.messageCount))
        }
        let limits = SharedRateLimitData.shared
        return RosterSnapshot(
            machineId: machineId,
            displayName: MachineIdentity.resolvedDisplayName(
                setting: settings.machineDisplayName,
                fallback: MachineIdentity.defaultDisplayName()),
            publishedAt: now,
            sessionPct: limits.sessionPct,
            weeklyPct: limits.weeklyPct,
            panes: rows.sorted { $0.paneIndex < $1.paneIndex })
    }

    private func publish() {
        guard settings.rosterEnabled, let snapshot = snapshot() else { return }
        if task == nil { connectIfConfigured() }
        guard let task,
              let data = try? JSONEncoder().encode(snapshot),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                // Drop the socket so the next change reconnects. A send error
                // on a hibernated peer is routine, not a fault.
                self?.logger.notice("roster: send failed, will reconnect: \(error.localizedDescription, privacy: .public)")
                self?.task = nil
            }
        }
    }
}
```

- [ ] **Step 2: Hold the publisher in `CanopyApp`**

Alongside the existing `MacroPadController` in `AppDelegate`, and started the same way:

```swift
    private var rosterPublisher: RosterPublisher?
```

and in `applicationDidFinishLaunching`, after the MacroPad start:

```swift
        let publisher = RosterPublisher(store: store, settings: CanopySettings.shared)
        publisher.start()
        rosterPublisher = publisher
```

- [ ] **Step 3: Build**

```bash
cd ~/repos/Personal/Canopy && ./scripts/build_debug_stable.sh
```

Expected: build succeeds.

- [ ] **Step 4: Verify end to end against the deployed Worker**

Set the endpoint and secret, turn the toggle on in Settings, open two sessions, and read the DO back:

```bash
# Paste the secret into Settings → Mobile → Relay secret first; it goes to
# the Keychain. Never export it into a shell that a transcript records.
open build/Build/Products/Debug/Canopy.app
# then, after opening two panes:
/usr/bin/log show --predicate 'subsystem == "sh.saqoo.Canopy" AND category == "Roster"' --last 2m --style compact
```

Expected: a `roster: connected as <uuid>` line. If nothing appears, check `rosterEnabled` and the endpoint — not the build.

- [ ] **Step 5: Commit**

```bash
cd ~/repos/Personal/Canopy
jj describe -r @ -m "Publish this Mac's panes to the relay on every change

Observation tracking in MacroPadController's shape — the same problem, already
solved once here. Every snapshot is full, because the Durable Object replaces
rather than merges and a dropped update must not strand a closed pane on the
phone. Off by default; the endpoint and the toggle are Settings."
jj new
```

---

### Task 5: The Worker serves the roster

**Files:**
- Modify: `~/repos/Personal/Canopy-Mobile/worker/src/machine.ts`
- Modify: `~/repos/Personal/Canopy-Mobile/worker/src/index.ts`
- Modify: `~/repos/Personal/Canopy-Mobile/worker/src/machine.test.ts`

**Interfaces:**
- Consumes: `MachineDO.currentSnapshot()`, `MachineSnapshot`.
- Produces: route `GET /roster?machine=<id>` returning `MachineSnapshot | null` as JSON.

- [ ] **Step 1: Write the failing test**

```typescript
it("serves a stored snapshot over HTTP", async () => {
  const id = env.MACHINE.idFromName("mac:CCCC-3333");
  const stub = env.MACHINE.get(id);
  await runInDurableObject(stub, async (instance: any) => {
    instance.applySnapshot({ ...snapshot, machineId: "CCCC-3333" });
  });
  const res = await stub.fetch("https://do/roster");
  expect(res.status).toBe(200);
  const body = (await res.json()) as MachineSnapshot;
  expect(body.machineId).toBe("CCCC-3333");
});

it("returns 404 for a Mac that has never published", async () => {
  const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:NEVER"));
  const res = await stub.fetch("https://do/roster");
  expect(res.status).toBe(404);
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npm test
```

Expected: FAIL — the DO's `fetch` returns 426 for a non-upgrade request.

- [ ] **Step 3: Route inside the DO's `fetch`**

Replace the body of `MachineDO.fetch` with:

```typescript
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/roster") {
      const snapshot = this.currentSnapshot();
      if (!snapshot) return new Response("not found", { status: 404 });
      return new Response(JSON.stringify(snapshot), {
        headers: { "Content-Type": "application/json" },
      });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const pair = new WebSocketPair();
    // Hibernation API. `pair[1].accept()` would bill an idle connection.
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }
```

- [ ] **Step 4: Add the Worker route**

In `index.ts`, before the 404:

```typescript
    if (url.pathname === "/roster") {
      const machine = url.searchParams.get("machine");
      if (!machine) return new Response("machine required", { status: 400 });
      const stub = env.MACHINE.get(env.MACHINE.idFromName(`mac:${machine}`));
      return stub.fetch(new Request("https://do/roster"));
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npm test
```

Expected: PASS, 4 tests.

- [ ] **Step 6: Deploy and read a real Mac's roster**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npx wrangler deploy
curl -H "Authorization: Bearer $CANOPY_ROSTER_SECRET" \
  "https://canopy-mobile-relay.<subdomain>.workers.dev/roster?machine=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}')"
```

Expected: JSON with the panes currently open in Canopy.

- [ ] **Step 7: Commit**

```bash
cd ~/repos/Personal/Canopy-Mobile
git add -A
git commit -m "feat: serve a Mac's stored roster over HTTP"
```

---

### Task 6: The phone shows one Mac's roster

**Files:**
- Create: `~/repos/Personal/Canopy-Mobile/project.yml`
- Create: `~/repos/Personal/Canopy-Mobile/Sources/CanopyMobileApp.swift`
- Create: `~/repos/Personal/Canopy-Mobile/Sources/RosterModels.swift`
- Create: `~/repos/Personal/Canopy-Mobile/Sources/RosterClient.swift`
- Create: `~/repos/Personal/Canopy-Mobile/Sources/RosterView.swift`

**Interfaces:**
- Consumes: `GET /roster?machine=<id>`.
- Produces: `MachineSnapshot` / `PaneRow` (Swift mirrors of `worker/src/types.ts`), `RosterClient.fetch(machine:) async throws -> MachineSnapshot`.

- [ ] **Step 1: Write `project.yml`**

xcodegen, matching Pager's and Canopy's convention of generating the project rather than committing it.

```yaml
name: CanopyMobile
options:
  bundleIdPrefix: sh.saqoo
  deploymentTarget:
    iOS: "18.0"
targets:
  CanopyMobile:
    type: application
    platform: iOS
    sources: [Sources]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: sh.saqoo.canopy-mobile
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
```

- [ ] **Step 2: Write `Sources/RosterModels.swift`**

```swift
import Foundation

/// Mirrors `worker/src/types.ts`. The two are kept in step by hand; the
/// probe assertion in the Canopy repo pins the key names on the sending side.
struct PaneRow: Codable, Identifiable, Equatable {
    let sessionId: String
    let paneIndex: Int
    let title: String
    let project: String
    let state: String
    let stateSince: Int
    let contextPct: Int
    let model: String
    let messageCount: Int

    var id: String { sessionId }
}

struct MachineSnapshot: Codable, Equatable {
    let machineId: String
    let displayName: String
    let publishedAt: Int
    let sessionPct: Int
    let weeklyPct: Int
    let panes: [PaneRow]
}
```

- [ ] **Step 3: Write `Sources/RosterClient.swift`**

```swift
import Foundation

struct RosterClient {
    let baseURL: URL
    let secret: String

    func fetch(machine: String) async throws -> MachineSnapshot {
        var components = URLComponents(url: baseURL.appendingPathComponent("roster"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "machine", value: machine)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(MachineSnapshot.self, from: data)
    }
}
```

- [ ] **Step 4: Write `Sources/RosterView.swift`**

The colours are the phone's third rendering of the same six states the sidebar dots and the MacroPad LEDs already show. Keep the names; the exact hues are the app's to choose.

```swift
import SwiftUI

struct RosterView: View {
    let snapshot: MachineSnapshot?
    let now: Date

    var body: some View {
        List {
            if let snapshot {
                Section {
                    ForEach(snapshot.panes) { pane in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(color(for: pane.state))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pane.title).font(.body)
                                Text(pane.project).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(elapsed(since: pane.stateSince))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(snapshot.displayName) — 5h \(snapshot.sessionPct)% · wk \(snapshot.weeklyPct)%")
                }
            } else {
                Text("No roster yet").foregroundStyle(.secondary)
            }
        }
    }

    private func color(for state: String) -> Color {
        switch state {
        case "working": return .cyan
        case "background": return .purple
        case "asking": return .orange
        case "unread": return .green
        case "error": return .red
        default: return .gray
        }
    }

    /// Time in state. "40m asking" and "asking" mean entirely different
    /// things, which is why the snapshot carries a stamp rather than a flag.
    private func elapsed(since unix: Int) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970) - unix)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
```

- [ ] **Step 5: Write `Sources/CanopyMobileApp.swift`**

```swift
import SwiftUI

@main
struct CanopyMobileApp: App {
    @State private var snapshot: MachineSnapshot?
    @State private var now = Date()

    private let client = RosterClient(
        baseURL: URL(string: ProcessInfo.processInfo.environment["ROSTER_URL"] ?? "https://example.invalid")!,
        secret: ProcessInfo.processInfo.environment["ROSTER_SECRET"] ?? "")
    private let machine = ProcessInfo.processInfo.environment["ROSTER_MACHINE"] ?? ""

    var body: some Scene {
        WindowGroup {
            RosterView(snapshot: snapshot, now: now)
                .task {
                    snapshot = try? await client.fetch(machine: machine)
                }
                .refreshable {
                    snapshot = try? await client.fetch(machine: machine)
                }
        }
    }
}
```

Configuration through the environment is deliberate for this task: the point is to prove the data arrives, and a settings screen would be work that the multi-Mac task replaces anyway.

- [ ] **Step 6: Generate and build**

```bash
cd ~/repos/Personal/Canopy-Mobile && xcodegen generate
xcodebuild -project CanopyMobile.xcodeproj -scheme CanopyMobile \
  -destination 'generic/platform=iOS Simulator' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Run in the simulator against the real Worker**

Set `ROSTER_URL`, `ROSTER_SECRET` and `ROSTER_MACHINE` in the scheme's environment, run, and confirm the panes currently open in Canopy appear.

- [ ] **Step 8: Commit**

```bash
cd ~/repos/Personal/Canopy-Mobile
git add -A
git commit -m "feat: iOS app showing one Mac's roster"
```

---

### Task 7: Live updates while foregrounded

**Files:**
- Modify: `~/repos/Personal/Canopy-Mobile/worker/src/machine.ts`
- Modify: `~/repos/Personal/Canopy-Mobile/worker/src/index.ts`
- Modify: `~/repos/Personal/Canopy-Mobile/worker/src/machine.test.ts`
- Create: `~/repos/Personal/Canopy-Mobile/Sources/RosterSocket.swift`
- Modify: `~/repos/Personal/Canopy-Mobile/Sources/CanopyMobileApp.swift`

**Interfaces:**
- Consumes: `MachineDO`'s accepted sockets.
- Produces: route `GET /watch?machine=<id>` (WebSocket); `RosterSocket.connect(machine:onSnapshot:)`, `.disconnect()`.

- [ ] **Step 1: Write the failing test**

```typescript
it("forwards a publisher's snapshot to a watching socket", async () => {
  const stub = env.MACHINE.get(env.MACHINE.idFromName("mac:DDDD-4444"));
  const watcher = await stub.fetch("https://do/watch", {
    headers: { Upgrade: "websocket" },
  });
  const ws = watcher.webSocket!;
  ws.accept();
  const received = new Promise<string>((resolve) => {
    ws.addEventListener("message", (e) => resolve(e.data as string));
  });
  await runInDurableObject(stub, async (instance: any) => {
    instance.applySnapshot({ ...snapshot, machineId: "DDDD-4444" });
    instance.broadcast();
  });
  const body = JSON.parse(await received) as MachineSnapshot;
  expect(body.machineId).toBe("DDDD-4444");
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npm test
```

Expected: FAIL — `instance.broadcast is not a function`.

- [ ] **Step 3: Tag sockets by role and broadcast**

`getWebSockets()` returns every accepted socket after hibernation, publishers included, so a role tag is what keeps the DO from echoing a snapshot back to the Mac that sent it. Attachments survive hibernation; in-memory sets do not.

In `machine.ts`, replace the upgrade branch of `fetch` and add `broadcast`:

```typescript
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const role = url.pathname === "/watch" ? "watcher" : "publisher";
    const pair = new WebSocketPair();
    // Hibernation API. `pair[1].accept()` would bill an idle connection.
    this.ctx.acceptWebSocket(pair[1]);
    // Attachments survive hibernation; an in-memory Set would not.
    pair[1].serializeAttachment({ role });
    return new Response(null, { status: 101, webSocket: pair[0] });
```

and, as a method:

```typescript
  /** Send the current snapshot to every watcher. Publishers are skipped. */
  broadcast(): void {
    const snapshot = this.currentSnapshot();
    if (!snapshot) return;
    const text = JSON.stringify(snapshot);
    for (const ws of this.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as { role?: string } | null;
      if (attachment?.role !== "watcher") continue;
      try {
        ws.send(text);
      } catch {
        // A watcher that has gone away is routine; the next publish retries.
      }
    }
  }
```

and call it at the end of `webSocketMessage`:

```typescript
    this.applySnapshot(parsed);
    this.broadcast();
```

- [ ] **Step 4: Add the Worker route**

In `index.ts`, before the 404:

```typescript
    if (url.pathname === "/watch") {
      const machine = url.searchParams.get("machine");
      if (!machine) return new Response("machine required", { status: 400 });
      const stub = env.MACHINE.get(env.MACHINE.idFromName(`mac:${machine}`));
      return stub.fetch(request);
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npm test
```

Expected: PASS, 5 tests.

- [ ] **Step 6: Write `Sources/RosterSocket.swift`**

```swift
import Foundation

/// Holds a WebSocket only while the app is foregrounded. Backgrounding drops
/// it: iOS would suspend it anyway, and a hibernated Durable Object bills
/// nothing for a connection that is not there.
@MainActor
final class RosterSocket {
    private var task: URLSessionWebSocketTask?
    private let baseURL: URL
    private let secret: String

    init(baseURL: URL, secret: String) {
        self.baseURL = baseURL
        self.secret = secret
    }

    func connect(machine: String, onSnapshot: @escaping (MachineSnapshot) -> Void) {
        disconnect()
        var components = URLComponents(url: baseURL.appendingPathComponent("watch"),
                                       resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "machine", value: machine)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(on: task, onSnapshot: onSnapshot)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive(on task: URLSessionWebSocketTask,
                         onSnapshot: @escaping (MachineSnapshot) -> Void) {
        task.receive { [weak self] result in
            guard case .success(.string(let text)) = result,
                  let data = text.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(MachineSnapshot.self, from: data)
            else { return }
            Task { @MainActor in
                onSnapshot(snapshot)
                self?.receive(on: task, onSnapshot: onSnapshot)
            }
        }
    }
}
```

- [ ] **Step 7: Connect on foreground, disconnect on background**

In `CanopyMobileApp.swift`, add `@Environment(\.scenePhase) private var scenePhase`, hold a `RosterSocket`, and:

```swift
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        socket.connect(machine: machine) { snapshot = $0 }
                    default:
                        socket.disconnect()
                    }
                }
```

- [ ] **Step 8: Verify on device or simulator**

Open the app, change a pane's state in Canopy (send a prompt), and watch the dot change without a pull-to-refresh. Background the app and confirm `wrangler tail` shows the socket closing.

- [ ] **Step 9: Commit**

```bash
cd ~/repos/Personal/Canopy-Mobile
git add -A
git commit -m "feat: live roster while the app is foregrounded"
```

---

### Task 8: Multiple Macs

**Files:**
- Modify: `~/repos/Personal/Canopy-Mobile/worker/src/index.ts`
- Create: `~/repos/Personal/Canopy-Mobile/worker/src/index.test.ts`
- Modify: `~/repos/Personal/Canopy-Mobile/Sources/CanopyMobileApp.swift`
- Modify: `~/repos/Personal/Canopy-Mobile/Sources/RosterView.swift`
- Create: `~/repos/Personal/Canopy-Mobile/Sources/MachineDirectory.swift`

**Interfaces:**
- Consumes: `MachineDO`, `MachineSnapshot`.
- Produces: KV binding `MACHINES` (a set of known machine ids); route `GET /machines`; `MachineDirectory.all() async throws -> [String]`.

- [ ] **Step 1: Add the KV binding**

The phone cannot enumerate Durable Objects, so the Worker records every machine that has ever published.

In `wrangler.toml`:

```toml
[[kv_namespaces]]
binding = "MACHINES"
id = "<create with: npx wrangler kv namespace create MACHINES>"
```

- [ ] **Step 2: Write the failing test**

```typescript
// worker/src/index.test.ts
import { env, SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";

const auth = { Authorization: `Bearer ${(env as any).SHARED_SECRET}` };

describe("machine directory", () => {
  it("lists a machine after it publishes", async () => {
    await SELF.fetch("https://relay/publish?machine=EEEE-5555", {
      headers: { ...auth, Upgrade: "websocket" },
    });
    const res = await SELF.fetch("https://relay/machines", { headers: auth });
    const body = (await res.json()) as string[];
    expect(body).toContain("EEEE-5555");
  });

  it("refuses an unauthenticated listing", async () => {
    const res = await SELF.fetch("https://relay/machines");
    expect(res.status).toBe(401);
  });
});
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npm test
```

Expected: FAIL — `/machines` returns 404.

- [ ] **Step 4: Record and list machines in `index.ts`**

Add `MACHINES: KVNamespace` to `Env`, then in the `/publish` branch, before forwarding:

```typescript
      await env.MACHINES.put(`machine:${machine}`, "1");
```

and before the 404:

```typescript
    if (url.pathname === "/machines") {
      const listed = await env.MACHINES.list({ prefix: "machine:" });
      const ids = listed.keys.map((k) => k.name.slice("machine:".length));
      return new Response(JSON.stringify(ids), {
        headers: { "Content-Type": "application/json" },
      });
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd ~/repos/Personal/Canopy-Mobile/worker && npm test
```

Expected: PASS, 7 tests.

- [ ] **Step 6: Write `Sources/MachineDirectory.swift`**

```swift
import Foundation

struct MachineDirectory {
    let baseURL: URL
    let secret: String

    func all() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("machines"))
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([String].self, from: data)
    }
}
```

- [ ] **Step 7: One socket per Mac, one section per Mac**

In `CanopyMobileApp.swift`, replace the single `snapshot` with `@State private var snapshots: [String: MachineSnapshot] = [:]`, hold one `RosterSocket` per machine id, and on `.active` fetch `MachineDirectory.all()` then connect each. In `RosterView`, take `snapshots` and render one `Section` per machine, sorted by `displayName`, each header carrying that Mac's own quota — which is the point of the split, since a Mac at 95% and one at 2% are different places to start work.

- [ ] **Step 8: Verify with two Macs publishing**

Turn `rosterEnabled` on in Canopy on both Macs, open the app, and confirm two sections with the right names and independent quota.

- [ ] **Step 9: Commit**

```bash
cd ~/repos/Personal/Canopy-Mobile
git add -A
git commit -m "feat: roster across every Mac that has published"
```

---

## Not in this plan

Carried from the spec, so an executor does not add them unasked:

- Canopy-originated notifications and the hook change in the Pager repo — **build-order steps 4-5, a separate plan.**
- Reply. Nothing here injects a prompt.
- Any current-tool or transcript content in the roster. The six states are the whole contract.
- A phone-side rename. The display name is a Canopy setting; the spec records why.
