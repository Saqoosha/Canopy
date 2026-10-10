# Learnings: Shim-specific

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **Never inject authStatus into `update_state`; `init_response` only** — it breaks logout/re-login. `tengu_vscode_cc_auth` must be forced true.
- **Extension responses are unwrapped, unsolicited messages are `{type:"from-extension", message:...}`** — dump the shape at your hook point (`CANOPY_CJK_DEBUG=1`), never copy a consumer's test.
- **CJK repair constraints** (`cjk-emphasis.js`, `cjk-emphasis-stream.js`) — flanking context is the last EMITTED code point; only non-ASCII punctuation moves; chunk splits must not change output, hence the held-back tail released before `content_block_stop`. `CANOPY_DISABLE_CJK_EMPHASIS_REPAIR=1` disables it.
- **Do NOT line-buffer the shim's stderr** — an undecodable chunk is dropped whole, so a residual glues across the hole and fabricates a line matching `process exited with code`. If built, make it `Data`-level.
- **An extension update can kill activation silently** — `ExtensionContext` (`context.js`) is a hand-written subset; a missing member (e.g. `workspaceState`) throws in `activate`, the shim exits 1 and the pane bounces to the launcher. Look for `Unknown ExtensionContext member:` and the `.error` log `Shim error: Extension activation failed` (has `stack`).
- **Cheap A/B without building Canopy** — `HOME=$(mktemp -d) node <shim>/index.js --extension-path <ext> --cwd <dir> --settings-path <settings>` with stdin held open; failure exits 1, success prints `MCP Server running on port`. The scratch `HOME` is required (shared `storagePath`, real MCP port, `~/.claude/ide/<port>.lock`).
- **`canopyAssignedEnvKeys` is an explicit list, not a `CANOPY_*` prefix sweep** — a sweep would drop dev overrides like `CANOPY_CJK_DEBUG`. It is scrubbed in BOTH spawners (`ShimProcess`, `RemoteSessionsBridge`).
- **SSH patches in `index.js`**: `realpathSync` tolerates `ENOENT`; `spawn` rewrites a missing `cwd` to `$HOME` only for `CANOPY_SSH_WRAPPER_PATH` commands (others must fail cleanly). Per-session config goes through `envOverrides` in `workspace.js`, not the shared settings file.
