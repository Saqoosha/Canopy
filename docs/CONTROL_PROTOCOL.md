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

`id` and `verb` must be non-empty. Omitted `params` is `{}`. Some errors
also carry a stable `errorCode` to branch on (so far only `open_session`
with `resumeSessionId`); branch on it rather than on `error`'s wording.

A session is named by `key` (the daemon's `OpenSession` id) and/or
`sessionId` (the resume id). Both may be sent; `key` is tried first.
Prefer `key` for follow-up calls: `open_session`'s `sessionId` is a
placeholder the CLI replaces.

## Verbs

### Already on the socket

This list is partial.

`list_sessions` takes optional `limit` (default 50) and `scope` (`open`
default, or `recent`).

`scope: "recent"` lists past sessions, most recently active first. These are
the rows `open_session`'s `resumeSessionId` continues. Without filters it
returns the newest sessions the daemon keeps (about 50). With any filter
it reads every transcript on the Mac. The first such read takes a few
seconds; later ones reuse cached headers.
`limit` is at most 500 here. Params:

| Param | Meaning |
|---|---|
| `query` | Whitespace-separated words; every one must appear (case-insensitive) in the title, project, cwd or first prompt |
| `project` | Text the project name or cwd contains (case-insensitive) |
| `since`, `until` | Keep sessions active at some point in the period. A `yyyy-MM-dd` date (this Mac's time zone; the whole day), an ISO 8601 date-time, or Unix seconds. Anything else is an error |
| `includeOpen` | `true` also lists open sessions, with `key` and live `state` |

A row adds these fields to the `open` scope's:

| Field | Meaning |
|---|---|
| `sessionId` | The id to pass as `resumeSessionId`. Same value as `resumeId` |
| `startedAt` | Unix seconds of the transcript's first timestamped record, when it has one |
| `firstPrompt` | The first thing a person typed, when the transcript's header holds it; cut at 500 characters. Hook output, slash-command and IDE markup, and tool results are skipped |

`title` is the session's title: the name it was given or generated,
otherwise the start of its first message. Closed rows have `state`
`"closed"`, no `key`, and empty `model` / `permissionMode`.

```sh
canopyctl sessions --project ghostline --since 2026-10-01 --table
canopyctl sessions --query "VDGS layout"        # JSON, open sessions included
```

`open_session` requires `cwd`, an absolute path of a directory that exists.
Optional: `permissionMode` (a `PermissionMode` raw value; `bypassPermissions`
is refused unless the daemon's bypass gate is on), `model`, `effort`,
`worktreeBranch`, `initialPrompt`. A non-empty `initialPrompt` is submitted
as the session's first turn. When no pane is attached the daemon synthesizes
`init` then `launch_claude` on channel `canopy-headless`, so the turn runs
without a webview and a later attach still has a cached init.

The result is `{sessionId, key, cwd}`, plus `replyId` when `initialPrompt`
was given. Pass that `replyId` to `wait_turn` to wait for the first answer.

#### Continuing a session

`open_session` with `resumeSessionId` continues an existing conversation
instead of starting one: a session that was closed, or that a daemon restart
dropped. The CLI is started with `--resume`, so the model has the whole
conversation. Find the id with `list_sessions` `scope: "recent"` (each row's
`sessionId`).

The folder is the session's own, resolved the way the GUI reopens a closed
row. It handles a session that moved into a worktree, and a removed
worktree whose checkout is known. `cwd` is optional. When given, it must be
a folder the transcript is filed under. `model` and `permissionMode` default
to what the transcript last recorded; pass them to override. `effort` is not
recorded, so it uses the CLI default unless given. An inherited
`bypassPermissions` becomes this Mac's default mode while the bypass gate is
off. `worktreeBranch` cannot be combined with `resumeSessionId`.
`initialPrompt` is sent as the next turn.

The result is `{sessionId, key, cwd, alreadyOpen, permissionMode}`, plus
`model` when one is set and `replyId` when `initialPrompt` was given. If the
session is already open, nothing new is started: `alreadyOpen` is true and
`key` names the open session. `cwd`, `model`, `effort` and `permissionMode`
are not applied then (they are still parsed, so a malformed one is refused). An open session that is not
running (launch-restored, or its process exited) is restarted as itself.
An `initialPrompt` to a session that is already running goes through
`send_message`'s queue, so the result also carries that verb's `disposition`
and `ok` (`reason` when queued; `reason` and `reasonCode` when refused).

A refusal is an error response with an `errorCode` beside `error`:

| `errorCode` | Meaning |
|---|---|
| `invalid_session_id` | `resumeSessionId` is not a session id (UUID) |
| `no_transcript` | No transcript for this id on this Mac (an SSH remote session's is on the other machine) |
| `folder_missing` | The session's folder, or the given `cwd`, is gone (or the transcript names none), and no checkout was found to reopen it in |
| `cwd_mismatch` | The transcript is not filed under the given `cwd` |
| `invalid_cwd` | `cwd` is not an absolute path |
| `worktree_not_supported` | `worktreeBranch` was given |
| `invalid_permission_mode` | Unknown `permissionMode` |
| `bypass_disabled` | `bypassPermissions` was asked for while the bypass gate is off |
| `start_failed` | The session could not be started |

```sh
canopyctl sessions --project ghostline --table
canopyctl resume <sessionId> --initial-prompt "Next: …"   # same as: open --resume <sessionId>
canopyctl wait --key <key> --reply-id <replyId>
```

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
| `turn_interrupted` | A turn ended without a `result`: its CLI was stopped, died, or the daemon exited (below). Never resent |
| `permission` | A tool permission request arrived |
| `asking` | An AskUserQuestion arrived |
| `session_opened`, `session_closed` | A session was added to or removed from the daemon's open list. `session_opened` carries the id the session had then; a new session's placeholder id is replaced after its first turn. `session_closed` carries `reason` (below) |
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

`isError` is on every `turn_done`: `false` when the turn finished, `true`
when it ended on an error. A failed turn also carries `errorKind` and, when
the CLI named one, `errorCode` (the CLI's own value, kept for causes this
table does not split out). `text` follows the same rule as on a finished
turn, so a failed turn can still be addressed: check `isError`. With no
addressed block it is the CLI's `result` text, which is the error message on
an API error and empty for `max_turns`, `budget` and `execution`:

| `errorKind` | Cause |
|---|---|
| `auth` | Login rejected, expired or not allowed (`authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `verification_required`, `cloud_credential_error`) |
| `rate_limit` | A usage limit was hit |
| `billing` | A billing problem on the account |
| `overloaded` | The API was overloaded |
| `network` | `server_error` with no HTTP status (measured: connection refused). A lost connection the CLI reports as `unknown` is `other` |
| `server` | The API answered with a server error |
| `max_turns`, `budget`, `execution` | The CLI's `error_max_turns`, `error_max_budget_usd`, `error_during_execution` |
| `other` | Anything else: `model_not_found`, `invalid_request`, `unknown`, `max_output_tokens` included |

The daemon does not retry a failed turn (the CLI retries some errors itself
before failing it).

`turn_interrupted` replaces the `turn_done` a turn will never get. It carries
`reason`, and `replyId` / `prompt` as `turn_done` would, so a client can
decide to send the prompt again; the daemon never does. `prompt` is absent
when the CLI had not echoed it yet.

| `reason` | Why |
|---|---|
| `stopped` | The CLI was stopped on purpose: `stop_session`, `restart_session`, an account switch |
| `crashed` | The CLI exited on its own. The session stays open but not running (no `session_closed`); `open_session` with its `resumeSessionId` starts it again |
| `daemon_restart` | The daemon is shutting down; followed by that session's `session_closed` |

`reason` on `session_closed`:

| `reason` | Why |
|---|---|
| `stopped` | `stop_session`, which the Mac's Stop also sends |
| `reaped` | The reaper stopped it: no client attached and idle past the limit (below). A session `open_session` started is not reaped while a `listen` covers it (below) |
| `daemon_restart` | The daemon is shutting down (an update, Restart now, launchd, SIGTERM); recorded for every open session just before it exits. `resumes: true` when the next daemon will reopen it (below) |
| `restore_failed` | Recorded by the next daemon for a session it said `resumes` for and could not reopen |
| `other` | Removed by a path that did not say why |

Result on timeout:

```json
{"timedOut":true,"cursor":"1a2b3c4d.57"}
```

Pass `cursor` as the next `since` in both cases. The part before the dot
changes when a daemon starts without a saved log (after a crash; a clean
restart keeps it, below); a cursor from an earlier epoch returns
`{"event":"gap","reason":"daemon_restarted"}` at once, and its `cursor`
resumes at the oldest event the new daemon holds. `reason: "overflow"` means
the ring wrapped past the cursor; `"unknown_cursor"` means the cursor is
ahead of the log.

### Across a daemon restart

A daemon that exits cleanly (an update, Restart now, launchd stopping it,
SIGTERM) saves its event log and the next one continues it: same epoch, same
seqs, so a cursor from before the restart goes on with no `gap`, and events
recorded during the shutdown are still there to read. A daemon that crashed
saved nothing, and a cursor from it returns `gap` `daemon_restarted` as
before. The saved log is owner-only (it holds prompts and replies) and is
read once.

When the exit is a restart (an update, Restart now, a failed local socket),
sessions whose CLI `open_session` started (opened new, or resumed when not
already running), and those the phone opened, come back under the same `key`:
`session_closed` says `resumes: true`, and the new daemon records
`session_opened` with `reason: "restored"`. Its shim is running; the CLI
resumes the transcript (`--resume`) on the next attach or `send_message`. A
session it cannot bring back (it fails to start, or the daemon was down more
than 10 minutes) gets `session_closed` with `reason: "restore_failed"`. A
session opened less than a turn ago (no transcript yet) cannot be resumed and
says `resumes: false`. Others, a Mac pane's included, come back when their
client re-attaches. A daemon stopped with SIGTERM (bootout, logout) carries
no session: every close says `resumes: false`.

### Idle sessions

The reaper stops a session with no client attached once it has been idle for
the limit in Settings (4 hours by default; "Never" turns it off). A session
`open_session` started is kept while some `listen` covers it: one naming its
`key` or `sessionId`, or one naming no session. It stays covered for 2
minutes after its last listen ends, so a client that re-sends `listen` after
every event (`--follow`) covers it continuously. Once no listen covers it,
the usual rule applies again: a session already idle past the limit is
stopped at the reaper's next pass.

While a connection has a `listen` open, the daemon sends
`{"type":"heartbeat","at":<seconds>}` on it every 30 s. It answers no
request; a client ignores it except as proof the connection is alive, so 90 s
with nothing at all means the connection is dead. Older daemons send none;
`--follow` then asks again each time a quiet listen goes 90 s without a byte.

`canopyctl listen --follow` keeps listening and prints one response line per
event. It reconnects on its own, with the same cursor, when the daemon goes
away (waiting 1 s, doubling to 30 s), and never exits on a timeout; it exits
1 on a refused `hello` or an error response and 130 on Ctrl-C. With
`--cursor-file PATH` it starts from the cursor in that file (unless `--since`
is given) and rewrites the file after every response, so a restarted
follower picks up where it stopped: the cursor is written only after the
event line has been printed and flushed. Without a starting cursor, events
before its first request are not seen. `--cursor-file` works without
`--follow` too.

```sh
canopyctl listen --follow --to Engineer --cursor-file ~/.engineer.cursor |
  while read -r line; do printf '%s\n' "$line"; done   # handle each event
```

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
