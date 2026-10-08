# Control protocol

A local agent drives this Mac's Canopy daemon over a Unix socket. The GUI
uses the same connection. This page is the wire a script needs; the server
design lives in
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

## Verbs

### Already on the socket

`list_sessions` takes no params.

`open_session` requires `cwd`, an absolute path of a directory that exists.
Optional: `permissionMode` (a `PermissionMode` raw value; `bypassPermissions`
is refused unless the daemon's bypass gate is on), `model`, `effort`,
`worktreeBranch`, `initialPrompt`. A non-empty `initialPrompt` is submitted
as the session's first turn. When no pane is attached the daemon synthesizes
`launch_claude` on channel `canopy-headless`, so the turn runs without a
webview.

`stop_session` and `restart_session` take `key` and/or `sessionId`.

`subscribe` asks for `session_state` pushes. Those lines are not responses.

`mkdir` and `create_folder` both create a directory and stay separate verbs.
Unifying them is a follow-up.

### `send_message`

Puts text on a live session through the same queue the phone uses
(`PhoneReplyQueue`, capacity 10). A busy session queues the text. A session
that is not running, or that is waiting on a permission prompt or an
AskUserQuestion, refuses it.

Params: `key` and/or `sessionId`, required `text` (trimmed; blank is
`"The message was empty"`). A non-empty `attachments` array is refused
(`"attachments are not supported"`). Omit attachments.

Result:

```json
{"ok":true,"disposition":"injected","replyId":"<id>"}
```

`disposition` is `injected`, `queued`, or `refused`. `ok` is false only for
`refused`. `queued` and `refused` may include `reason`. `replyId` identifies
this control turn for the status verbs.

### `session_status`, `latest_reply`, `wait_turn`

All three take optional `key`, `sessionId`, and `replyId`. A blank or
omitted `replyId` means the control turn in flight, or the last one that
finished.

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
