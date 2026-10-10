# Learnings: First-render races the pane strip exposes

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

Launch restore builds N panes in one tick; both races show a blank white pane with a healthy shim and nothing in logs.

- **Whoever is on screen must hold the WKWebView; do not pick a winning host** — SwiftUI calls `makeNSView` twice and keeps either; `SessionWebViewHost.expectedWebView` re-adopts it in `viewDidMoveToWindow` and `updateNSView`.
- **Entry HTML is one file per session and must outlive the load** — `webViewWebContentProcessDidTerminate` reloads that URL; a shared file raced `data-initial-session`.
- **Delete only entry files this process wrote** (`purgeOwnEntryFiles` via `noteEntryFileWritten`) — `~/Library/Application Support/Canopy` is shared with the Release build.
- **Nothing in `applicationDidFinishLaunching` may read `panes`** — the restore applies from a `.task`, with ordering relative to the delegate not guaranteed.
