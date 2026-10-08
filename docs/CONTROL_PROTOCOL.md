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
| `empty` | The text was blank | No |

A busy session is not refused; the message is `queued`.

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
cut to about 4 KB. `choices` appears only on `question`. An empty list means
nothing is waiting, which includes a session that is not running.

### `session_status`, `latest_reply`, `wait_turn`

All three take optional `key`, `sessionId`, and `replyId`. An unknown
`replyId` (never sent, refused, or dropped at teardown) is an error
`unknown reply id`. Without `replyId`, a queued control message reports
`turnDone: false`. Prefer the `replyId` from `send_message`.

`latest_reply` reports the last CONTROL turn, not turns typed on the Mac
or phone.

`state` is `idle`, `working`, or `asking` (`asking` when the last assistant
turn raised AskUserQuestion, otherwise `working` while a turn is running).
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
