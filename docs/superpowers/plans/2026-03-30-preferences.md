# Canopy Preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS Settings window (Cmd+,) with 4 Claude Code preferences, backed by a global JSON file that the vscode-shim reads via getConfiguration.

**Architecture:** New `CanopySettings` observable model reads/writes `~/Library/Application Support/Canopy/settings.json`. Settings UI is a SwiftUI `Settings` scene. The shim receives the settings path via `--settings-path` and adds it as the top-priority layer in `getConfiguration`.

**Tech Stack:** Swift 6, SwiftUI, Node.js (vscode-shim)

---

### Task 1: shim `--settings-path` argument and getConfiguration integration

**Files:**
- Modify: `Resources/vscode-shim/index.js:24-39` (arg parsing)
- Modify: `Resources/vscode-shim/index.js:107-111` (createWorkspace call)
- Modify: `Resources/vscode-shim/workspace.js:255-337` (createConfiguration + createWorkspace)
- Test: `test/shim-unit.test.js`

- [ ] **Step 1: Write failing test for Canopy settings layer**

Add to the `workspace` test suite in `test/shim-unit.test.js`:

```javascript
it("getConfiguration reads Canopy global settings with highest priority", () => {
  // Write a Canopy global settings file
  const canopySettingsPath = path.join(tmpDir, "canopy-settings.json");
  fs.writeFileSync(canopySettingsPath, JSON.stringify({
    "claudeCode.initialPermissionMode": "plan",
    "claudeCode.respectGitIgnore": false,
  }));

  const ws2 = createWorkspace({
    cwd: tmpDir,
    settingsPath: path.join(tmpDir, ".vscode", "settings.json"),
    canopySettingsPath,
    extensionPackageJson: {},
  });

  const config = ws2.getConfiguration("claudeCode");
  assert.equal(config.get("initialPermissionMode"), "plan");
  assert.equal(config.get("respectGitIgnore"), false);
  assert.equal(config.has("initialPermissionMode"), true);
});

it("getConfiguration falls through when Canopy settings has no value", () => {
  const canopySettingsPath = path.join(tmpDir, "canopy-settings.json");
  fs.writeFileSync(canopySettingsPath, JSON.stringify({}));

  const ws2 = createWorkspace({
    cwd: tmpDir,
    settingsPath: path.join(tmpDir, ".vscode", "settings.json"),
    canopySettingsPath,
    extensionPackageJson: {
      contributes: {
        configuration: { properties: { "claudeCode.respectGitIgnore": { default: true } } },
      },
    },
  });

  const config = ws2.getConfiguration("claudeCode");
  assert.equal(config.get("respectGitIgnore"), true);
});

it("getConfiguration inspect includes Canopy settings as globalValue", () => {
  const canopySettingsPath = path.join(tmpDir, "canopy-settings.json");
  fs.writeFileSync(canopySettingsPath, JSON.stringify({
    "claudeCode.useCtrlEnterToSend": true,
  }));

  const ws2 = createWorkspace({
    cwd: tmpDir,
    settingsPath: path.join(tmpDir, ".vscode", "settings.json"),
    canopySettingsPath,
    extensionPackageJson: {},
  });

  const config = ws2.getConfiguration("claudeCode");
  const info = config.inspect("useCtrlEnterToSend");
  assert.equal(info.globalValue, true);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `node --test test/shim-unit.test.js`
Expected: 3 failures — `createWorkspace` doesn't accept `canopySettingsPath` yet.

- [ ] **Step 3: Add `--settings-path` to arg parsing in index.js**

In `Resources/vscode-shim/index.js`, add to `parseArgs`:

```javascript
    } else if (arg === "--settings-path" && argv[i + 1]) {
      args.settingsPath = argv[++i];
    }
```

And pass it to `createWorkspace`:

```javascript
  const workspace = createWorkspace({
    cwd: args.cwd,
    settingsPath: path.join(args.cwd, ".vscode", "settings.json"),
    canopySettingsPath: args.settingsPath,
    extensionPackageJson,
  });
```

- [ ] **Step 4: Add Canopy settings layer to createConfiguration in workspace.js**

Update `createConfiguration` signature and add Canopy settings as highest-priority layer:

```javascript
function createConfiguration(settingsPath, extensionPackageJson, canopySettingsPath) {
```

In the returned `getConfiguration(section)` closure, load Canopy settings:

```javascript
  return function getConfiguration(section) {
    const userSettings = loadJson(settingsPath);
    const canopySettings = canopySettingsPath ? loadJson(canopySettingsPath) : {};

    return {
      get(key, defaultValue) {
        const fullKey = section ? `${section}.${key}` : key;

        // 1. Canopy global settings (highest priority)
        if (Object.prototype.hasOwnProperty.call(canopySettings, fullKey)) {
          return canopySettings[fullKey];
        }
        // 2. User settings (.vscode/settings.json)
        if (Object.prototype.hasOwnProperty.call(userSettings, fullKey)) {
          return userSettings[fullKey];
        }
        // 3. Extension package.json defaults
        if (Object.prototype.hasOwnProperty.call(extDefaults, fullKey)) {
          return extDefaults[fullKey];
        }
        // 4. VSCode built-in defaults (files.exclude, search.exclude, etc.)
        if (Object.prototype.hasOwnProperty.call(VSCODE_BUILTIN_DEFAULTS, fullKey)) {
          return VSCODE_BUILTIN_DEFAULTS[fullKey];
        }
        // 5. Provided default
        return defaultValue;
      },

      has(key) {
        const fullKey = section ? `${section}.${key}` : key;
        return (
          Object.prototype.hasOwnProperty.call(canopySettings, fullKey) ||
          Object.prototype.hasOwnProperty.call(userSettings, fullKey) ||
          Object.prototype.hasOwnProperty.call(extDefaults, fullKey) ||
          Object.prototype.hasOwnProperty.call(VSCODE_BUILTIN_DEFAULTS, fullKey)
        );
      },

      update(key, value, _target) {
        const fullKey = section ? `${section}.${key}` : key;
        const current = loadJson(settingsPath);
        if (value === undefined) {
          delete current[fullKey];
        } else {
          current[fullKey] = value;
        }
        saveJson(settingsPath, current);
      },

      inspect(key) {
        const fullKey = section ? `${section}.${key}` : key;
        const currentSettings = loadJson(settingsPath);
        const defVal = Object.prototype.hasOwnProperty.call(extDefaults, fullKey)
          ? extDefaults[fullKey]
          : Object.prototype.hasOwnProperty.call(VSCODE_BUILTIN_DEFAULTS, fullKey)
            ? VSCODE_BUILTIN_DEFAULTS[fullKey]
            : undefined;
        // Canopy settings appear as globalValue (highest user-level setting)
        const canopyVal = Object.prototype.hasOwnProperty.call(canopySettings, fullKey)
          ? canopySettings[fullKey]
          : undefined;
        const workspaceVal = Object.prototype.hasOwnProperty.call(currentSettings, fullKey)
          ? currentSettings[fullKey]
          : undefined;
        return {
          key: fullKey,
          defaultValue: defVal,
          globalValue: canopyVal ?? workspaceVal ?? undefined,
          workspaceValue: workspaceVal ?? undefined,
          workspaceFolderValue: undefined,
        };
      },
    };
  };
}
```

Update `createWorkspace` to accept and pass `canopySettingsPath`:

```javascript
function createWorkspace({ cwd, settingsPath, canopySettingsPath, extensionPackageJson }) {
  // ...
  const getConfiguration = createConfiguration(
    settingsPath || path.join(cwd, ".vscode", "settings.json"),
    extensionPackageJson || {},
    canopySettingsPath,
  );
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `node --test test/shim-unit.test.js`
Expected: All tests pass including the 3 new ones.

- [ ] **Step 6: Commit**

```
feat: add Canopy settings layer to shim getConfiguration

- Parse --settings-path CLI argument in index.js
- Add canopySettingsPath as highest-priority layer in getConfiguration
- Canopy settings appear as globalValue in inspect() for extension compatibility
```

---

### Task 2: CanopySettings model

**Files:**
- Create: `Sources/Canopy/CanopySettings.swift`

- [ ] **Step 1: Create CanopySettings.swift**

```swift
import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Canopy", category: "CanopySettings")

@Observable
final class CanopySettings {
    static let shared = CanopySettings()

    var initialPermissionMode: PermissionMode = .acceptEdits {
        didSet { save() }
    }
    var allowDangerouslySkipPermissions: Bool = false {
        didSet {
            if !allowDangerouslySkipPermissions && initialPermissionMode == .bypassPermissions {
                initialPermissionMode = .acceptEdits
            }
            save()
        }
    }
    var useCtrlEnterToSend: Bool = false {
        didSet { save() }
    }
    var respectGitIgnore: Bool = true {
        didSet { save() }
    }

    let filePath: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let canopyDir = appSupport.appendingPathComponent("Canopy")
        self.filePath = canopyDir.appendingPathComponent("settings.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: filePath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            logger.info("No settings file found, using defaults")
            return
        }

        if let mode = dict["claudeCode.initialPermissionMode"] as? String,
           let pm = PermissionMode(rawValue: mode) {
            initialPermissionMode = pm
        }
        if let allow = dict["claudeCode.allowDangerouslySkipPermissions"] as? Bool {
            allowDangerouslySkipPermissions = allow
        }
        if let ctrl = dict["claudeCode.useCtrlEnterToSend"] as? Bool {
            useCtrlEnterToSend = ctrl
        }
        if let git = dict["claudeCode.respectGitIgnore"] as? Bool {
            respectGitIgnore = git
        }
        logger.info("Loaded settings: permissionMode=\(self.initialPermissionMode.rawValue, privacy: .public)")
    }

    private func save() {
        let dict: [String: Any] = [
            "claudeCode.initialPermissionMode": initialPermissionMode.rawValue,
            "claudeCode.allowDangerouslySkipPermissions": allowDangerouslySkipPermissions,
            "claudeCode.useCtrlEnterToSend": useCtrlEnterToSend,
            "claudeCode.respectGitIgnore": respectGitIgnore,
        ]
        do {
            let dir = filePath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: filePath)
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodegen generate && xcodebuild -project Canopy.xcodeproj -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```
feat: add CanopySettings model for global preferences

- Reads/writes ~/Library/Application Support/Canopy/settings.json
- 4 settings: initialPermissionMode, allowDangerouslySkipPermissions,
  useCtrlEnterToSend, respectGitIgnore
- Auto-resets bypassPermissions if allowDangerously is disabled
```

---

### Task 3: Settings UI

**Files:**
- Create: `Sources/Canopy/SettingsView.swift`
- Modify: `Sources/Canopy/CanopyApp.swift:10-16` (add Settings scene)

- [ ] **Step 1: Create SettingsView.swift**

```swift
import SwiftUI

struct SettingsView: View {
    @Bindable var settings = CanopySettings.shared

    var body: some View {
        Form {
            Picker("Permission Mode", selection: $settings.initialPermissionMode) {
                Text(PermissionMode.default.displayName).tag(PermissionMode.default)
                Text(PermissionMode.acceptEdits.displayName).tag(PermissionMode.acceptEdits)
                Text(PermissionMode.auto.displayName).tag(PermissionMode.auto)
                Text(PermissionMode.plan.displayName).tag(PermissionMode.plan)
                if settings.allowDangerouslySkipPermissions {
                    Text(PermissionMode.bypassPermissions.displayName).tag(PermissionMode.bypassPermissions)
                }
            }

            Toggle("Allow Bypass Permissions Mode", isOn: $settings.allowDangerouslySkipPermissions)

            Toggle("Use Ctrl+Enter to Send", isOn: $settings.useCtrlEnterToSend)

            Toggle("Respect .gitignore in File Search", isOn: $settings.respectGitIgnore)
        }
        .formStyle(.grouped)
        .frame(width: 450)
        .fixedSize()
    }
}
```

- [ ] **Step 2: Add Settings scene to CanopyApp.swift**

After the `WindowGroup` in `CanopyApp.body`, add:

```swift
        Settings {
            SettingsView()
        }
```

- [ ] **Step 3: Build and verify**

Run: `xcodegen generate && xcodebuild -project Canopy.xcodeproj -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```
feat: add Settings window with 4 preference items

- SwiftUI Settings scene (Cmd+, to open)
- Permission mode picker, allow bypass toggle, ctrl+enter toggle, gitignore toggle
- Bypass option only visible when allowDangerouslySkipPermissions is enabled
```

---

### Task 4: Wire AppState and LauncherView to CanopySettings

**Files:**
- Modify: `Sources/Canopy/AppState.swift`
- Modify: `Sources/Canopy/LauncherView.swift:99-112`

- [ ] **Step 1: Update AppState to read from CanopySettings**

Replace `AppState`'s permission mode logic:

```swift
@Observable
final class AppState {
    private(set) var screen: AppScreen = .launcher
    var workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var permissionMode: PermissionMode {
        get { CanopySettings.shared.initialPermissionMode }
        set { CanopySettings.shared.initialPermissionMode = newValue }
    }
    var resumeSessionId: String?
    var resumeSessionTitle: String?
    var debugAutoLaunchDir: String?
    private(set) var webviewReloadToken = 0

    init() {
        debugAutoLaunchDir = UserDefaults.standard.string(forKey: "debugAutoLaunchDir")
    }
```

This removes the `UserDefaults` storage for `permissionModeKey` entirely — `CanopySettings` is now the single source of truth.

- [ ] **Step 2: Update LauncherView permission picker to use CanopySettings**

Replace the `permissionPicker` in `LauncherView.swift`:

```swift
    private var permissionPicker: some View {
        HStack {
            Text("Permission Mode")
                .font(.subheadline)
            Spacer()
            Picker("", selection: $appState.permissionMode) {
                Text(PermissionMode.default.displayName).tag(PermissionMode.default)
                Text(PermissionMode.acceptEdits.displayName).tag(PermissionMode.acceptEdits)
                Text(PermissionMode.auto.displayName).tag(PermissionMode.auto)
                Text(PermissionMode.plan.displayName).tag(PermissionMode.plan)
                if CanopySettings.shared.allowDangerouslySkipPermissions {
                    Text(PermissionMode.bypassPermissions.displayName).tag(PermissionMode.bypassPermissions)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
        }
    }
```

- [ ] **Step 3: Build and verify**

Run: `xcodegen generate && xcodebuild -project Canopy.xcodeproj -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```
refactor: wire AppState and LauncherView to CanopySettings

- AppState.permissionMode now delegates to CanopySettings.shared
- Remove UserDefaults storage for permission mode
- LauncherView picker respects allowDangerouslySkipPermissions
```

---

### Task 5: Pass settings path to shim process

**Files:**
- Modify: `Sources/Canopy/ShimProcess.swift:114-119`

- [ ] **Step 1: Add --settings-path to shim launch arguments**

In `ShimProcess.start()`, add after `--permission-mode`:

```swift
        args.append(contentsOf: ["--permission-mode", permissionMode.rawValue])
        args.append(contentsOf: ["--settings-path", CanopySettings.shared.filePath.path])
        proc.arguments = args
```

- [ ] **Step 2: Add debug logging for settings verification**

In the `init_response` patching section (around line 562), add a log before the existing patch:

```swift
            logger.info("init_response state from extension: initialPermissionMode=\(state["initialPermissionMode"] as? String ?? "nil", privacy: .public) allowSkip=\(state["allowDangerouslySkipPermissions"] as? Bool ?? false, privacy: .public)")
```

- [ ] **Step 3: Build and verify**

Run: `xcodegen generate && xcodebuild -project Canopy.xcodeproj -scheme Canopy -configuration Debug -derivedDataPath build build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Run shim unit tests**

Run: `node --test test/shim-unit.test.js`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```
feat: pass Canopy settings path to shim process

- Add --settings-path argument to shim launch
- Add debug logging to verify extension reads settings from getConfiguration
- Keep existing init_response/update_state patches as Phase 1 safety net
```
