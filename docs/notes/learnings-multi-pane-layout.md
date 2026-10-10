# Learnings: Multi-pane layout

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`. Rules already in CLAUDE.md are not repeated.

- **Never feed `NSWindow.didResizeNotification` into pane widths** — observer grows `preferredWidth`, the layout grows the window, the notification fires again (window reached 100000+ pt). Weights are re-synced lazily by `normalizePaneWeightsToVisualWidths()`.
- **Measure the sidebar only with `PaneWindowSizer.measuredSidebarWidthTrustingCollapse`** — a collapsed sidebar (width 0) must be trusted everywhere; a policy that assumes 280 in one place drifts the window ~280 pt per pane add/close.
- **Resize the window synchronously in `schedulePaneResize`** — a debounce or animated `setFrame` makes the WKWebView scroll position drift.
- **Flush headers need `.toolbar(removing: .title)` plus the per-child `.ignoresSafeArea`; do not use `.toolbar(.hidden, for: .windowToolbar)`** — it removes the traffic lights.
- **`windowTitle` returns "Canopy" when `panes.count > 1`** — the title is shown once, in `PaneHeaderStrip`.
