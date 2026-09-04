# Permission response — captured wire shape

**Captured:** 2026-09-04, from three real clicks in a Canopy Debug session
(permission mode `Default`).
**Extension:** `anthropic.claude-code-2.1.90-darwin-arm64`.
**Why captured rather than read:** the extension's webview bundle is minified
(`tool_permission_response",result:q`), so neither the field name nor its legal
values are readable from it.

## The envelope Canopy sees

`ShimProcess.userContentController` receives, from the webview:

```json
{
  "type": "response",
  "requestId": "<32 hex chars>",
  "response": {
    "type": "tool_permission_response",
    "result": { "behavior": "allow" | "deny", ... }
  }
}
```

**The outer `type` is `"response"`, not `"tool_permission_response"`.** The
latter is the inner message's own type. An earlier draft of the plan filtered on
the wrong one and would have captured nothing.

**Key order is not stable.** Across the three captures `type`, `requestId` and
`response` appeared in different orders — parse by key, never by position.

## The decision lives at `response.result.behavior`

Two values, both observed: `"allow"` and `"deny"`. **Not** a bare
`"result": "allow"`, which is what the shape would have been guessed as.

### Allow — verbatim

```json
{"requestId":"51f4436599eec97e3a8df7e560c4ef95","type":"response",
 "response":{"result":{"behavior":"allow","updatedPermissions":[],
 "updatedInput":{"command":"…","description":"…"}},
 "type":"tool_permission_response"}}
```

`updatedInput` echoes the tool's input back, so the UI can offer an edited
command. A phone decision has nothing to edit and should echo the input it was
shown, unchanged.

### Deny — verbatim

```json
{"type":"response","requestId":"2475fbc1e0ff554ed70a2c405511ecb9",
 "response":{"type":"tool_permission_response",
 "result":{"behavior":"deny","interrupt":true,
 "message":"The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."}}}
```

**`message` and `interrupt` are part of the contract, not decoration.** The
message is the text the model receives as the tool result; `interrupt: true` is
what stops the turn rather than letting it continue. A synthesized deny must
send both, with that exact message — it is what the CLI's own UI sends.

### Allow Always — verbatim

```json
{"requestId":"f5cc93c1ee0585ac9367880520c235b5",
 "response":{"type":"tool_permission_response",
 "result":{"behavior":"allow",
 "updatedPermissions":[{"type":"addRules","destination":"session",
 "behavior":"allow","rules":[{"toolName":"Read","ruleContent":"/Users/hiko/.claude/**"}]}],
 "updatedInput":{"file_path":"/Users/hiko/.claude/settings.local.json"}}},
 "type":"response"}
```

**Allow Always is not a third `behavior`.** It is `allow` plus a populated
`updatedPermissions` carrying an `addRules` entry whose `ruleContent` the UI
derived from the tool input. Reproducing it from the phone would mean deriving
that rule remotely — **out of scope**; the phone offers Allow and Deny only, and
`updatedPermissions` stays `[]`.

## What this pins for the implementation

- Route on `requestId`, which is per process. A decision for an id not in
  `pendingPermissionRequestIds` must be dropped and logged.
- Send `behavior: "allow"` with `updatedPermissions: []` and the original
  `updatedInput`, or `behavior: "deny"` with `interrupt: true` and the verbatim
  message above.
- `Canopy`'s existing `trackPermissionResponse` already clears the pending id
  off the outer envelope, so a synthesized response will close the loop through
  the same path a real click does — **verify that on device**, do not assume it.
