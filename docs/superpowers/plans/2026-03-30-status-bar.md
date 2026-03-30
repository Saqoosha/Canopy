# Status Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native Swift status bar below the WKWebView showing context usage, rate limits, cost, model info, and CLI version.

**Architecture:** Native SwiftUI `StatusBarView` below `WKWebView` in a VStack. ShimProcess extracts data from CLI NDJSON events and intercepts `usage_update` messages. Data published via `@Observable` model. CLI version read from extension's package.json at startup.

**Tech Stack:** Swift 6, SwiftUI, `@Observable` macro

---

## Data Sources (Confirmed by Research)

| Data | Source | When |
|------|--------|------|
| Context used | `stream_event` → `message_start` → `usage.input_tokens + cache_creation + cache_read` | Every turn |
| Context max | `result` → `modelUsage[model].contextWindow` | Every turn |
| 5hr % + reset | `usage_update` request (extension → webview, passes through shim) → `utilization.fiveHour.{utilization, resetsAt}` | Periodic |
| Weekly % + reset | Same → `utilization.sevenDay.{utilization, resetsAt}` | Periodic |
| Cost | `result` → `total_cost_usd` | Every turn |
| Model | `stream_event` → `message_start` → `message.model` | Every turn |
| CLI version | `CCExtension.extensionPath()/package.json` → `version` | Startup |
| Message count | Count `user`/`assistant` io_message events | Every message |

### usage_update Message Format (passes through ShimProcess as webview_message)

Extension sends to webview:
```json
{
  "type": "request",
  "request": {
    "type": "usage_update",
    "utilization": {
      "fiveHour": {"utilization": 0.55, "resetsAt": "2026-03-30T04:30:00Z"},
      "sevenDay": {"utilization": 0.45, "resetsAt": "2026-04-03T00:00:00Z"},
      "sevenDaySonnet": {"utilization": 0.0, "resetsAt": "2026-04-05T00:00:00Z"}
    }
  }
}
```

This arrives in ShimProcess's `handleShimMessage` as a `webview_message` with this structure inside `innerMessage` (wrapped in `from-extension`).

---

## Display Target

```
v2.1.87 [Opus 4.6] · 171K/800K ██▒▒▒▒ 21% · $1.23 · 5hr: 55% ⏳18m · Wk: 45% ⏳4d · 42 msgs
```

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Sources/Canopy/StatusBarData.swift` | Create | `@Observable` data model |
| `Sources/Canopy/StatusBarView.swift` | Create | SwiftUI compact bar view |
| `Sources/Canopy/ShimProcess.swift` | Modify | Extract data from CLI events + intercept usage_update |
| `Sources/Canopy/CanopyApp.swift` | Modify | Add StatusBarView to session layout |
| `Sources/Canopy/WebViewContainer.swift` | Modify | Pass StatusBarData to ShimProcess |
| `Sources/Canopy/CCExtension.swift` | Modify | Add version reading from package.json |

---

## Tasks

### Task 1: StatusBarData + StatusBarView + CCExtension version

### Task 2: Wire into app layout (CanopyApp + WebViewContainer)

### Task 3: ShimProcess data extraction (context, model, cost, messages)

### Task 4: ShimProcess intercept usage_update (5hr, weekly rate limits)

### Task 5: Polish and test
