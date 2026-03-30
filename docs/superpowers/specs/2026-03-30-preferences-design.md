# Canopy Preferences Design

## Overview

Add a macOS native Settings window (Cmd+,) with 4 Claude Code configuration items, backed by a global settings file. The shim's `getConfiguration` reads these values so the extension picks them up natively.

## Settings

| Key | Type | Default | UI Control |
|-----|------|---------|------------|
| `claudeCode.initialPermissionMode` | string | `"acceptEdits"` | Picker: Default / Accept Edits / Plan / Bypass |
| `claudeCode.allowDangerouslySkipPermissions` | boolean | `false` | Toggle |
| `claudeCode.useCtrlEnterToSend` | boolean | `false` | Toggle |
| `claudeCode.respectGitIgnore` | boolean | `true` | Toggle |

The "Bypass" option in the Permission Mode picker is only visible when `allowDangerouslySkipPermissions` is enabled.

## Settings File

**Path**: `~/Library/Application Support/Canopy/settings.json`

Keys use the `claudeCode.*` prefix matching VSCode's format so the shim's `getConfiguration` can read them directly.

```json
{
  "claudeCode.initialPermissionMode": "acceptEdits",
  "claudeCode.allowDangerouslySkipPermissions": false,
  "claudeCode.useCtrlEnterToSend": false,
  "claudeCode.respectGitIgnore": true
}
```

## Architecture

### Settings UI — `SettingsView.swift` (new)

SwiftUI `Settings` scene added to `CanopyApp.swift`. Single pane, 4 items. Binds to `CanopySettings` observable object.

### Settings Model — `CanopySettings.swift` (new)

`@Observable` class that reads/writes `settings.json`. Provides typed properties for each setting. File is read once on init, written on every change.

### shim `getConfiguration` — `workspace.js` (modified)

Add a new top-priority layer to the lookup chain:

```
1. Canopy global settings (~/Library/Application Support/Canopy/settings.json)
2. Extension package.json defaults
3. VSCode built-in defaults (VSCODE_BUILTIN_DEFAULTS)
4. Provided default
```

The Canopy settings path is passed to the shim via `--settings-path` CLI argument.

### shim entry — `index.js` (modified)

Parse `--settings-path <path>` argument. Pass to `createWorkspace()`.

### AppState — `AppState.swift` (modified)

`permissionMode` initial value reads from `CanopySettings` instead of `UserDefaults`. Launcher Picker writes back to `CanopySettings`.

### ShimProcess — `ShimProcess.swift` (modified)

- Add `--settings-path` to shim launch arguments
- Keep existing `init_response` / `update_state` patches (Phase 1 safety)
- Add debug logging to verify extension reads correct values from getConfiguration

## Hack Removal Strategy

### Phase 1 (this implementation)

- Implement Settings UI + file + shim integration
- **Keep** existing `init_response` / `update_state` permission patches as safety net
- Add logging to verify extension reads values from `getConfiguration("claudeCode")`
- **Keep** `launch_claude` permission override + `system/status` message (needed permanently for webview UI updates)
- **Keep** CLI `--permission-mode` argument (needed permanently for CLI process)

### Phase 2 (separate PR, after verification)

- Confirm via logs that extension reads settings correctly from getConfiguration
- Remove `init_response` permission/skip patches from ShimProcess
- Remove `update_state` permission/skip patches from ShimProcess

## File Changes

| File | Change |
|------|--------|
| `Sources/Canopy/SettingsView.swift` | **New** — SwiftUI Settings pane |
| `Sources/Canopy/CanopySettings.swift` | **New** — Settings read/write model |
| `Sources/Canopy/CanopyApp.swift` | Add `Settings` scene |
| `Sources/Canopy/AppState.swift` | Read permissionMode from CanopySettings |
| `Sources/Canopy/LauncherView.swift` | Bind Picker to CanopySettings |
| `Sources/Canopy/ShimProcess.swift` | Add `--settings-path` arg, add debug logging |
| `Resources/vscode-shim/workspace.js` | Add Canopy settings layer to getConfiguration |
| `Resources/vscode-shim/index.js` | Parse `--settings-path` argument |

## Testing

- Unit tests: add tests for `getConfiguration` Canopy settings layer in `shim-unit.test.js`
- Manual: change settings in Preferences, start new session, verify behavior changes
- Manual: check logs to confirm extension reads from getConfiguration
