# Control protocol

A local agent drives this Mac's Canopy daemon over a Unix socket. The GUI
uses the same connection. The same verbs are also reachable over the
token-authenticated Tailscale TCP listener. This page is the wire a script
needs; the server design lives in
`docs/superpowers/specs/2026-09-29-canopy-server-design.md`.

`scripts/canopyctl` is a small client for the verbs below.

## Socket

NDJSON, one JSON object per line.

Release:

```
~/Library/Application Support/Canopy/daemon-sh.saqoo.Canopy.sock
```

A Debug build uses `daemon-sh.saqoo.Canopy.debug.sock` in the same directory.
The two builds do not share a daemon. File mode is `0600`. A peer that can
open the socket is trusted; the local socket takes no token.

## Handshake

Client:

```json
{"type":"hello","protocolVersion":1}
```

`protocolVersion` is required and is `1` (`ControlProtocol.version`). An
absent version is version 0 and is refused. `client` is optional (the GUI
sends `"mac"`). `token` is only for a TCP peer; omit it on the local socket.

The server answers one line. `type` `hello_ok` means the connection is up.
`type` `hello_error` carries `message` and the socket closes. Treat any
other field on `hello_ok` as optional.

## Request and response

After `hello_ok`, the client sends requests and gets one response per `id`.

```json
{"type":"request","id":"<client-chosen>","verb":"<name>","params":{}}
```

```json
{"type":"response","id":"<same>","result":{}}
```

```json
{"type":"response","id":"<same>","error":"<message>"}
```

`id` and `verb` must be non-empty. Omitted `params` is `{}`.

A session is named by `key` (the daemon's `OpenSession` id) and/or
`sessionId` (the resume id). Both may be sent; `key` is tried first.
Prefer `key` for follow-up calls: `open_session`'s `sessionId` is a
placeholder the CLI replaces.

## Verbs

### Already on the socket

This list is partial.

`list_sessions` takes optional `limit` (default 50), `scope` (`open`
default, or `recent`), and `query` (with `recent`).

`open_session` requires `cwd`, an absolute path of a directory that exists.
Optional: `permissionMode` (a `PermissionMode` raw value; `bypassPermissions`
is refused unless the daemon's bypass gate is on), `model`, `effort`,
`worktreeBranch`, `initialPrompt`. A non-empty `initialPrompt` is submitted
as the session's first turn. When no pane is attached the daemon synthesizes
`init` then `launch_claude` on channel `canopy-headless`, so the turn runs
without a webview and a later attach still has a cached init.

The result is `{sessionId, key, cwd}`, plus `replyId` when `initialPrompt`
was given. Pass that `replyId` to `wait_turn` to wait for the first answer.

`stop_session` and `restart_session` take `key` and/or `sessionId`.

`subscribe` asks for `session_state` pushes. Those lines are not responses.
To wait for one event instead, use `listen` (below).

`mkdir` creates a directory (`parent`, `name`) and returns `{path}`.

### `send_message`

Puts text on a live session through the same queue the phone uses
(`PhoneReplyQueue`, capacity 10). A busy session queues the text. A session
that is not running, or that is waiting on a permission prompt or an
AskUserQuestion, refuses it. When the session has no channel and no client
attached, the daemon first sends a synthetic `init` then `launch_claude`
(same headless path as `open_session` with `initialPrompt`).

Params: `key` and/or `sessionId`, required `text` (trimmed; blank is
`"The message was empty"`). A non-empty `attachments` array is refused
(`"attachments are not supported"`). Omit attachments.

Result:

```json
{"ok":true,"disposition":"injected","replyId":"<id>"}
```

`disposition` is `injected`, `queued`, or `refused`. `ok` is false only for
`refused`. `queued` and `refused` may include `reason`. `replyId` identifies
this control turn for the status verbs — always pass it on follow-up calls.

A `refused` result also carries `reasonCode`, for deciding whether to retry:

| `reasonCode` | Meaning | Retry? |
|---|---|---|
| `dead` | The session is not running (it may be reconnecting) | Later |
| `permission_pending` | A permission prompt waits for a human | Not until it is answered |
| `asking` | An AskUserQuestion waits for a human | Not until it is answered |
| `queue_full` | 10 messages are already waiting | After the session catches up |

A busy session is not refused; the message is `queued`. Blank `text` never
reaches this table: it is an `error` response before anything is queued.

### `pending_requests`

Read-only. Lists what a session is waiting on a human for, so an agent can
tell that human; there is no verb to answer them. Params: `key` and/or
`sessionId`.

```json
{"requests":[{"requestId":"…","toolName":"Bash","kind":"permission","input":"…"},
             {"requestId":"…","toolName":"AskUserQuestion","kind":"question","input":"…",
              "choices":[{"question":"…","header":"…","options":[{"label":"…"}]}]}]}
```

`input` is the tool input rendered the way the phone's notification shows it,
cut to about 4 KB. `inputRaw` is the same input as structured JSON, omitted
when it exceeds 16 KB. `choices` appears only on `question`. An empty list means
nothing is waiting, which includes a session that is not running.

### `session_status`, `latest_reply`, `wait_turn`

All three take optional `key`, `sessionId`, and `replyId`. An unknown
`replyId` (never sent, refused, or dropped at teardown) is an error
`unknown reply id`. Without `replyId`, a queued control message reports
`turnDone: false`. Prefer the `replyId` from `send_message`.

`latest_reply` reports the last CONTROL turn, not turns typed on the Mac
or phone. To read those too, use `history`.

`state` is `idle`, `working`, `permission`, or `asking`. `asking` means an
AskUserQuestion is waiting; `permission` means a tool permission prompt is
waiting (`pending_requests` shows it); otherwise `working` while a turn is
running.
`turnDone` is true only after that control turn's result has been captured.
An in-flight control turn reports `turnDone: false` and no `text`, so a
previous answer is not reported as this turn.

`session_status` omits `text`:

```json
{"ok":true,"state":"working","turnDone":false,"replyId":"<id>"}
```

`latest_reply` adds `text` (the captured assistant text, or `""` when the
turn finished with none):

```json
{"ok":true,"state":"idle","turnDone":true,"replyId":"<id>","text":"..."}
```

`wait_turn` polls until `turnDone` or 60 seconds (0.5 s × 120), then returns
the same object as `latest_reply`. The client's read timeout has to be
longer than that; `canopyctl` uses 90 seconds.

### `history`

Read-only. The last turns of a session, read from its transcript, so turns
typed in a pane or on the phone are there as well as control turns, and so
are turns from before a daemon restart. Params: `key` and/or `sessionId`,
optional `limit` (turns, default 10, at most 50). A session that is no longer
open can still be read by `sessionId`. A session whose transcript is on
another machine (SSH remote, another Mac) is refused.

```json
{"key":"…","sessionId":"…","state":"idle",
 "turns":[{"prompt":"…","reply":"…","at":"2026-10-09T01:11:26.609Z","addressedTo":"Engineer"}]}
```

Turns are oldest first. `prompt` is what the person sent; it is absent on a
turn no one started (the model answering a background task's
notification). `reply` follows the same rule as `turn_done`'s `text`: from
the addressed block to the end when there is one, else the turn's last text
block. A turn still running has the text written so far, or `""`. Keep-alive
refreshes and subagent text are left out. `state` and `key` are present only
for an open session.

### `listen`

Blocks until something happens in a session this daemon runs, then answers
with that one event. This is how an agent learns about turns it did not
start. The daemon records events from launch whether or not anyone is
listening, in a ring of the last 1000, so a client that passes back its
cursor with the same filter misses nothing between two `listen` calls. SSH
remote sessions run in the GUI, not the daemon, and are not included.

Params, all optional:

| Param | Meaning |
|---|---|
| `events` | Array of event names to wait for. Default: every event except `addressed`. Unknown names are an error |
| `key`, `sessionId` | Only events from that session. Without `since` it must be open (else `no such session`); with `since` a session that has since closed is still read from the log |
| `addressedTo` | Only `addressed` turns whose reader contains this text (case-insensitive). Alone, it means `events: ["addressed"]`; with `events`, those must include `addressed` |
| `since` | A `cursor` string from an earlier `listen`. The first matching event after it is returned at once. Omitted: only events after this request |
| `timeout` | Seconds, default 300, at least 1, capped at 3600 |

A param of the wrong type is an error; `null` is the same as leaving it out. One connection may hold 16 open
`listen` requests; each is answered under its own `id`, and closing the
connection cancels them.

Events:

| `event` | When |
|---|---|
| `turn_done` | A main-conversation turn ended, whoever started it (Mac, phone, control API) |
| `addressed` | A filter, not a recorded kind: a `turn_done` whose reply names a reader (below). The returned `event` is `turn_done` with `addressedTo` |
| `permission` | A tool permission request arrived |
| `asking` | An AskUserQuestion arrived |
| `session_opened`, `session_closed` | A session was added to or removed from the daemon's open list. `session_opened` carries the id the session had then; a new session's placeholder id is replaced after its first turn |
| `gap` | Never requested. The cursor cannot be continued; resync with `list_sessions` |

A reply is addressed when the first non-blank line of one of the turn's text
blocks is `Written for: <name>` or `宛先: <name>` (markdown `#`, `>`, `*`,
`_` around the line is ignored). Every text block counts, not only the last:
a turn can go on after the addressed block (a Stop hook making the model
continue does this), and `result` holds only the last one.

Result when an event matched:

```json
{"cursor":"1a2b3c4d.42",
 "event":{"event":"turn_done","seq":42,"key":"…","sessionId":"…","title":"…","at":1791476315.48,
          "state":"idle","prompt":"…","replyId":"…","text":"Written for: Engineer\n…","addressedTo":"Engineer"}}
```

`prompt` on `turn_done` is what the person sent to start the turn, whether
typed in a pane, on the phone or through the control API; it is absent on a
turn no one started, and cut at 32,000 bytes with `promptTruncated: true`. `replyId` is present when the turn came from
`send_message` or an `initialPrompt`. `text` on `turn_done` is the turn's reply: from the addressed
block to the end when there is one, else the CLI's final `result` text, cut
at 32,000 bytes with `textTruncated: true`. `permission` and `asking` carry
`requestId`, `toolName`, and the rendered tool input as `text`, cut at about
4 KB like `pending_requests`. `state`, on those three kinds only, is the
session's state just after the event, as in `session_status`.

Result on timeout:

```json
{"timedOut":true,"cursor":"1a2b3c4d.57"}
```

Pass `cursor` as the next `since` in both cases. The part before the dot
changes each daemon launch; a cursor from an earlier launch returns
`{"event":"gap","reason":"daemon_restarted"}` at once, and its `cursor`
resumes at the oldest event the new daemon holds. `reason: "overflow"` means
the ring wrapped past the cursor; `"unknown_cursor"` means the cursor is
ahead of the log.

`canopyctl listen` prints the response and exits 0 on an event, 3 on
timeout, 4 when the socket could not be reached or dropped (a daemon
restart), and 1 on any other error, a refused `hello` included (2 is
argparse's usage error):

```sh
cursor=""
while :; do
  out=$(canopyctl listen --to Engineer --timeout 1800 ${cursor:+--since "$cursor"})
  rc=$?
  [ $rc -eq 4 ] && { sleep 5; continue; }   # keep the cursor and retry
  [ $rc -eq 0 ] || [ $rc -eq 3 ] || break
  cursor=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["cursor"])')
  [ $rc -eq 0 ] && printf '%s\n' "$out"   # handle the event
done
```
