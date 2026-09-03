# Canopy Mobile — design

**Date:** 2026-09-03
**Status:** design agreed, not implemented

A phone companion for Canopy. Two capabilities, one transport: **see every pane across every Mac**, and **reply to a notification with what to do next**.

## What already exists

Measured on 2026-09-03, not assumed.

- **Pager** (`~/repos/Personal/Pager`) is Saqoosha's own iOS app plus a Cloudflare Worker. It already round-trips: Mac hook → Worker `/notify` or `/request` → APNs → Pager, and back via a `UNNotificationAction` → `/status/<id>` polled by the hook. The permission flow ships `allow` / `deny` / `allowAlways` today.
- **Pager is multi-source.** `VALID_SOURCES = ["claude", "codex", "cursor"]`, allowlisted server-side.
- **Canopy sends nothing to Pager.** The notifications come from the Claude Code CLI hooks registered in `~/.claude/settings.json` (`notify-stop.sh`, `notify-notification.sh`, `permission-request.sh`). So `source: "claude"` means *Claude Code*, not *Canopy* — the same hooks fire from a terminal session.
- **Auth is a single shared secret**: `Bearer ${env.SHARED_SECRET}`.
- **`device_token` is one global KV key.** Pager does not distinguish Macs at all; a one-way notification never needed to.
- **Canopy's injection primitive is proven.** `ShimProcess.requestKeepAlive` calls `sendToShim` with an `io_message` carrying `{"role":"user","content":[{"type":"text","text":…}]}`. Substituting the phone's text makes it a real user turn.

## Scope

**In:** a roster of panes across Macs, live while the app is foregrounded; a free-text reply to a notification; Canopy-originated notifications carrying pane identity.

**Out:** reading the transcript, starting or closing sessions, switching panes, diff review. The ask was "see all pane/session stats on multiple mac and reply to notification what to do next" — everything else is a later decision, not a deferred task.

## Where the app lives

**A new iOS app.** Pager keeps `codex` and `cursor`; the whole `claude` source moves to Canopy Mobile.

The split is by *source*, not by *function*, and that is what makes it work: the notification, the roster and the reply all end up in one app, so "see a pane is stuck → tell it what to do" stays a single gesture. Splitting by function was considered and rejected for exactly that reason — you would tap a notification in one app and need another to answer it.

The split is clean because Saqoosha runs Claude Code essentially only inside Canopy. The residue is handled below.

## Backend

**A new Worker (`canopy-mobile-relay`), started from Pager's as a base.** Not a shared one.

`APNS_BUNDLE_ID` is a single Worker-level var in `wrangler.toml` (`sh.saqoo.pager-app`). A second app is a second bundle id and therefore a second APNs topic, so sharing one Worker means resolving that var per request — a change to the live, daily-use notification path, to buy nothing the split does not already give. Separate Workers also let this one start at a current `compatibility_date` instead of raising Pager's `2024-12-01`, and keep a Durable Object experiment from being able to take the pager down.

**Shared:** the APNs auth key, key id and team id. An APNs auth key is team-wide and serves every app on the team, so this is a secret to copy, not to re-issue.

**Not shared, and should not be:** device tokens (a separate app registers separately), KV, and the DO.

**Accepted cost:** two copies of the APNs sender — JWT signing, the send path, the 3000-character truncation — which will drift. That is the right trade because the two Workers diverge by design: one grows a DO, a roster and a WebSocket; the other stays a notification relay. Copy the module rather than rewriting it; the existing one is proven.

## Transport

```
Canopy (Mac A) ──┐
Canopy (Mac B) ──┼─→ DO "mac:<id>" ──→ Worker ──→ phone
Canopy (Mac C) ──┘   (one per Mac)        ↑
                                    WebSocket (foreground only)
                                    APNs (notifications)
```

One Durable Object per Mac, `getByName("mac:<id>")`; sessions are data inside it, not separate DOs. **Canopy dials out**, so no Mac needs an inbound port.

**`state.acceptWebSocket(ws)`, never `ws.accept()`.** This is not an optimisation: an active outbound connection bills up to 15 minutes per connection with no traffic, while the Hibernation API accrues no billable duration and keeps clients connected. In-memory state resets on hibernation, so anything undelivered must be queued in the DO's SQLite. DO works on the Workers Free plan, SQLite-backed only. The Worker's `compatibility_date` is `2024-12-01` and needs raising.

The phone holds a WebSocket **only while foregrounded**, and drops it on background — no battery cost, no billing, and notifications still arrive because they ride APNs on a separate path.

## What the roster carries

Per pane:

| Field | Source | Status |
|---|---|---|
| activity state | `SessionActivity` | exists — already drives the sidebar dots and the MacroPad LEDs. Seven cases, six of which can reach a roster row: `.empty` is a MacroPad key with no pane behind it, and a row only exists for a pane that holds a session |
| title, project · branch | `OpenSession.title` / `projectLabel` | exists |
| context %, model, message count | `StatusBarData` | exists |
| time in state | — | **new**: `SessionActivity` is computed and carries no stamp |

Per Mac: quota (5-hour and weekly) from `SharedRateLimitData.shared` — exists, and it is per-Mac, which is the point.

**The roster carries no conversation content.** "What it is doing right now" was considered at three levels — tool name only, tool name plus target, last assistant message — and cut to nothing for v1. The six reachable states already separate *generating* from *waiting on a background task* from *waiting on a human*, and `StatusBarData.subagents` already says how many subagents are running. A current-tool tracker is a documented extension point, in the shape `SubagentTracker` already uses to build rows from the io_message stream; it is not v1.

The notification path is a separate matter and does carry content: a permission request's text already crosses the network today through Pager's `/request`, and the hook stand-down below moves that same text from the hook to Canopy. Same content, different sender — not new exposure, but the roster's guarantee does not extend to notifications.

The DO stores current values, overwritten. No history.

## Identifying Macs

The existing single global `device_token` assumes one phone and one Mac. Two places now need the machine:

- **the roster**, to group rows and to attach the right quota;
- **the reply**, which has to choose a destination.

Canopy publishes two separate fields:

- **a stable id** — `IOPlatformUUID` (`ioreg -rd1 -c IOPlatformExpertDevice`, a 36-character UUID, verified readable), used for `getByName("mac:<id>")` and for all matching. Hostname was rejected: it changes with the network, and the whole point of the id is that renaming cannot move it;
- **a display name**, shown in the roster and embedded in notification text.

Keeping them separate is what makes renaming free later: the id never moves, so a rename breaks no session and no pending notification.

### The display name is a Canopy setting

A text field in Canopy's Settings, defaulting to `scutil --get ComputerName`.

**It has to live on the Mac, and notifications are what decide it.** iOS renders a notification banner from the payload; an app cannot rewrite one after the fact (a Notification Service Extension could, which is not worth a target for a name). So the name must be chosen *before the push is sent* — on the Mac. Putting it there also means the roster and the notification read one field, with no resolution order between a machine name and a nickname.

Canopy sends it with every publish and every notification. The Worker stores no copy, so the two cannot drift.

## Notifications

Canopy sends its own, and **a Canopy session skips the hook** so one event does not buzz the phone twice.

Without that, a session stopping inside Canopy fires both paths: the hook to Pager, and Canopy to Canopy Mobile. The fix is one line at the top of each of the three hook scripts:

```bash
# Canopy hosts this session and sends its own notification.
[ -n "$CANOPY_PANE" ] && exit 0
```

**Measured:** hooks inherit the CLI's environment (a `Stop` hook read a marker variable exported to `claude -p`). Canopy already exports several variables at spawn (`CLAUDE_CODE_SESSION_NAME`, `CANOPY_SSH_HOST`, …); `CANOPY_PANE` is new. There is no `CLAUDE_CODE_DISABLE_HOOKS`; `--settings <file>` exists but Canopy does not build the CLI's argv — the extension does. The environment variable is the only lever Canopy fully controls.

A session run from a terminal has no such variable, so the hook behaves exactly as it does today. So does every `codex` and `cursor` session.

What this buys: a Canopy notification can carry the pane index, the session title and the activity state. A hook sees only the CLI's JSON and cannot know any of them — and "reply with what to do next" needs to know *which pane*.

It also removes an edge. Claude Code run outside Canopy keeps notifying Pager, so a notification that Canopy cannot inject a reply into never appears in the app that offers to reply.

## Reply

The phone sends **`machine + sessionId + text`** and nothing else. The mapping stays server-side in KV, matching the existing `/request` pattern and respecting the APNs 4 KB limit — the Worker already truncates messages at 3000 characters for this.

Reuse `requestKeepAlive`'s busy-shim guard. **Never reuse its swallow latches.** Keep-alive deliberately hides its own traffic; a phone reply is the opposite and must appear in the transcript.

## Where the code lives

**A new repo, `Canopy-Mobile`, laid out like Pager** — `Sources/` for the iOS app, `worker/` for the Worker.

Two precedents from this author point the same way and were both checked: **Pager** already ships an iOS app and its Cloudflare Worker from one repo, which is exactly this shape; and **Canopy-MacroPad** is a sibling repo rather than a directory inside Canopy, so a companion living outside is the established choice.

Rejected:

- **Submodule.** `jj 0.43.0` has no `jj git submodule` (checked), so part of a jj-driven repo would fall back to raw git. The benefit submodules buy — pinning repositories to each other atomically — is for teams coordinating a release, not for one person.
- **Monorepo.** Would mean moving Canopy, which breaks its tags, the Sparkle appcast (`v2.24.1` names Canopy), and CI. No gain.
- **Inside the Canopy repo.** An iOS Xcode project would mix with a macOS-only `project.yml` and a `macos-26` CI job, and would muddy the release tags.

### The work spans three repos

| Repo | What |
|---|---|
| **Canopy** | publish state, send notifications, the Mac display-name setting, the `CANOPY_PANE` variable |
| **Pager** | the three hook scripts skip Canopy sessions. `~/.claude/hooks/*.sh` are **symlinks into `Pager/hooks/`** (checked), so this is where that edit belongs — not chezmoi, not Canopy |
| **Canopy-Mobile** (new) | the iOS app and the Worker |

The wire contract therefore lives in two repos, handled the way the MacroPad protocol already is: version the payload, and name which repo is primary for what — Canopy for the shape it publishes, Canopy-Mobile for how it is rendered.

## Build order

This is two features sharing a transport, and they decompose that way: steps 1-3 are the roster, steps 4-5 are notifications and reply. Each half deserves its own implementation plan; do not write one plan for all five.

1. **Canopy publishes state to a DO** — one Mac, no phone. The most uncertain step: neither the outbound connection nor hibernation has been exercised. Closest thing to a spike; if this fights back, the design is worth revisiting before anything else is built.
2. **The phone reads it** — minimal screen, one Mac, no live updates. Proves the data arrives.
3. **Multiple Macs, and live updates.**
4. **Hook stand-down, and Canopy-originated notifications.** Independent of the roster.
5. **Reply.** Last, because the injection primitive is already proven.

## Known limits, accepted

- **Renaming a Mac is a Canopy-side setting only.** You cannot fix a confusing name from the phone, which is where you notice it. Adding a phone-side override later costs one resolution step, and the stable id is already separate so it will not break anything.
- **A terminal Claude Code session gets no roster row**, by construction — it has no pane. Its notifications go to Pager.
- **No current-tool detail**, so the roster answers "is it stuck" but not "stuck on what". Deliberate; see above.

## Related

- `~/.claude/projects/-Users-hiko-repos-Personal-Canopy/memory/project_pager_mobile_reply_design.md` — the earlier, narrower reply-only design this supersedes. It concluded a mobile app was not needed; that conclusion held only while the ask was reply-only.
- `docs/superpowers/specs/2026-08-26-macropad-remote-transport-design.md` — the MacroPad is the other renderer of `SessionActivity`. The phone is a third, and adds no new state model.
