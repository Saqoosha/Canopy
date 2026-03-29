# VSCode Shim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Hangar's 1409-line Swift protocol handler with a Node.js vscode shim that runs the CC extension's `extension.js` unmodified.

**Architecture:** A Node.js subprocess (`vscode-shim/`) intercepts `require("vscode")` and bridges the extension's webview I/O to Hangar's WKWebView via stdin/stdout NDJSON. Swift side (`ShimProcess.swift`) manages the subprocess lifecycle and message forwarding.

**Tech Stack:** Node.js >= 18 (user-installed), Swift 6 / macOS 15, WKWebView, NDJSON over stdio

**Spec:** `docs/superpowers/specs/2026-03-29-vscode-shim-design.md`

---

## File Structure

```
Resources/vscode-shim/
  index.js            — Entry point: console redirect, Module hook, activate, main loop
  protocol.js         — writeStdout(), readStdin via readline, ready handshake
  types.js            — Uri, EventEmitter, Disposable, Range, Position, Selection, enums
  context.js          — ExtensionContext, globalState (JSON-backed), subscriptions
  workspace.js        — getConfiguration, workspaceFolders, findFiles, stubs
  commands.js         — registerCommand, executeCommand, setContext
  window.js           — webview bridge, registerWebviewViewProvider, createWebviewPanel
  notifications.js    — showInformationMessage, showErrorMessage, showWarningMessage (with timeout)
  env.js              — appName, uiKind, shell, remoteName, openExternal, clipboard
  stubs.js            — All Tier 2 stubs with warn-once logging

Sources/Hangar/
  ShimProcess.swift   — NEW: Node.js subprocess manager + stdio bridge
  NodeDiscovery.swift — NEW: Find and validate node binary
  WebViewContainer.swift — MODIFY: add ShimProcess integration alongside existing handler
  HangarApp.swift     — MODIFY: feature flag for shim mode
  AppState.swift      — MODIFY: add useShim flag

test/
  shim-unit.test.js         — Level 1: vscode API unit tests
  shim-integration.test.js  — Level 2: stdio integration with real extension.js
  helpers.js                — Test harness (spawnShim, waitFor, etc.)
```

---

## Task 1: NDJSON Protocol Layer

**Files:**
- Create: `Resources/vscode-shim/protocol.js`
- Test: `test/shim-unit.test.js`

- [ ] **Step 1: Write test for writeStdout**

```js
// test/shim-unit.test.js
const assert = require("node:assert");
const { describe, it, beforeEach } = require("node:test");

describe("protocol", () => {
  let written;
  let protocol;

  beforeEach(() => {
    written = [];
    protocol = require("../Resources/vscode-shim/protocol.js");
    // Replace stdout.write for testing
    protocol._setWriter((data) => written.push(data));
  });

  it("writeStdout writes JSON + newline", () => {
    protocol.writeStdout({ type: "ready" });
    assert.strictEqual(written.length, 1);
    assert.strictEqual(written[0], '{"type":"ready"}\n');
  });

  it("writeStdout handles nested objects", () => {
    protocol.writeStdout({ type: "webview_message", message: { type: "init" } });
    const parsed = JSON.parse(written[0]);
    assert.strictEqual(parsed.type, "webview_message");
    assert.strictEqual(parsed.message.type, "init");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
node --test test/shim-unit.test.js
```

Expected: FAIL — module not found

- [ ] **Step 3: Implement protocol.js**

```js
// Resources/vscode-shim/protocol.js
"use strict";

const readline = require("node:readline");

let _writer = (data) => process.stdout.write(data);

/** Override writer for testing */
function _setWriter(fn) { _writer = fn; }

/** Write a JSON message to stdout as NDJSON */
function writeStdout(msg) {
  _writer(JSON.stringify(msg) + "\n");
}

/**
 * Read NDJSON lines from stdin. Calls handler(parsed) for each valid line.
 * Invalid JSON lines are logged to stderr and skipped.
 */
function startStdinReader(handler) {
  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      const msg = JSON.parse(trimmed);
      handler(msg);
    } catch {
      process.stderr.write(`[vscode-shim] Invalid JSON on stdin: ${trimmed.slice(0, 200)}\n`);
    }
  });
  return rl;
}

module.exports = { writeStdout, startStdinReader, _setWriter };
```

- [ ] **Step 4: Run test to verify it passes**

```bash
node --test test/shim-unit.test.js
```

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Resources/vscode-shim/protocol.js test/shim-unit.test.js
git commit -m "feat(shim): add NDJSON protocol layer with stdin/stdout"
```

---

## Task 2: Core Types — Uri, EventEmitter, Disposable, Enums

**Files:**
- Create: `Resources/vscode-shim/types.js`
- Modify: `test/shim-unit.test.js`

- [ ] **Step 1: Write tests for Uri**

```js
// append to test/shim-unit.test.js
const { Uri, EventEmitter, Disposable } = require("../Resources/vscode-shim/types.js");

describe("Uri", () => {
  it("Uri.file creates file URI", () => {
    const uri = Uri.file("/foo/bar.txt");
    assert.strictEqual(uri.scheme, "file");
    assert.strictEqual(uri.fsPath, "/foo/bar.txt");
    assert.strictEqual(uri.path, "/foo/bar.txt");
  });

  it("Uri.joinPath appends segments", () => {
    const base = Uri.file("/foo");
    const joined = Uri.joinPath(base, "bar", "baz.txt");
    assert.strictEqual(joined.fsPath, "/foo/bar/baz.txt");
  });

  it("Uri.parse handles file URIs", () => {
    const uri = Uri.parse("file:///foo/bar");
    assert.strictEqual(uri.scheme, "file");
    assert.strictEqual(uri.fsPath, "/foo/bar");
  });

  it("Uri.parse handles http URIs", () => {
    const uri = Uri.parse("https://example.com/path");
    assert.strictEqual(uri.scheme, "https");
    assert.strictEqual(uri.authority, "example.com");
  });

  it("Uri.from creates URI from components", () => {
    const uri = Uri.from({ scheme: "file", path: "/test" });
    assert.strictEqual(uri.scheme, "file");
    assert.strictEqual(uri.fsPath, "/test");
  });

  it("Uri.toString produces string", () => {
    const uri = Uri.file("/foo/bar");
    assert.strictEqual(uri.toString(), "file:///foo/bar");
  });
});

describe("EventEmitter", () => {
  it("fire calls listeners", () => {
    const emitter = new EventEmitter();
    const received = [];
    emitter.event((data) => received.push(data));
    emitter.fire("hello");
    assert.deepStrictEqual(received, ["hello"]);
  });

  it("dispose removes listener", () => {
    const emitter = new EventEmitter();
    const received = [];
    const disposable = emitter.event((data) => received.push(data));
    emitter.fire("a");
    disposable.dispose();
    emitter.fire("b");
    assert.deepStrictEqual(received, ["a"]);
  });
});

describe("Disposable", () => {
  it("calls callback on dispose", () => {
    let called = false;
    const d = new Disposable(() => { called = true; });
    assert.strictEqual(called, false);
    d.dispose();
    assert.strictEqual(called, true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
node --test test/shim-unit.test.js
```

- [ ] **Step 3: Implement types.js**

```js
// Resources/vscode-shim/types.js
"use strict";

const nodePath = require("node:path");
const nodeUrl = require("node:url");

// --- Uri ---

class Uri {
  constructor(scheme, authority, path, query, fragment) {
    this.scheme = scheme || "";
    this.authority = authority || "";
    this.path = path || "";
    this.query = query || "";
    this.fragment = fragment || "";
  }

  get fsPath() {
    return this.scheme === "file" ? this.path : this.path;
  }

  with(change) {
    return new Uri(
      change.scheme ?? this.scheme,
      change.authority ?? this.authority,
      change.path ?? this.path,
      change.query ?? this.query,
      change.fragment ?? this.fragment,
    );
  }

  toString() {
    if (this.scheme === "file") return `file://${this.authority || ""}${this.path}`;
    if (this.authority) return `${this.scheme}://${this.authority}${this.path}`;
    return `${this.scheme}:${this.path}`;
  }

  toJSON() {
    return { scheme: this.scheme, authority: this.authority, path: this.path,
             query: this.query, fragment: this.fragment, fsPath: this.fsPath };
  }

  static file(fsPath) {
    return new Uri("file", "", nodePath.resolve(fsPath), "", "");
  }

  static parse(value) {
    try {
      const parsed = new URL(value);
      return new Uri(
        parsed.protocol.replace(":", ""),
        parsed.host || "",
        decodeURIComponent(parsed.pathname) || "",
        parsed.search.replace("?", ""),
        parsed.hash.replace("#", ""),
      );
    } catch {
      return new Uri("", "", value, "", "");
    }
  }

  static from({ scheme, authority, path, query, fragment }) {
    return new Uri(scheme, authority || "", path || "", query || "", fragment || "");
  }

  static joinPath(base, ...segments) {
    const joined = nodePath.join(base.path, ...segments);
    return base.with({ path: joined });
  }
}

// --- EventEmitter ---

class EventEmitter {
  constructor() {
    this._listeners = [];
    this.event = (listener) => {
      this._listeners.push(listener);
      return new Disposable(() => {
        const idx = this._listeners.indexOf(listener);
        if (idx >= 0) this._listeners.splice(idx, 1);
      });
    };
  }

  fire(data) {
    for (const listener of [...this._listeners]) {
      try { listener(data); } catch (e) {
        process.stderr.write(`[vscode-shim] EventEmitter listener error: ${e.message}\n`);
      }
    }
  }

  dispose() { this._listeners = []; }
}

// --- Disposable ---

class Disposable {
  constructor(callOnDispose) { this._callOnDispose = callOnDispose; }
  dispose() { if (this._callOnDispose) { this._callOnDispose(); this._callOnDispose = null; } }
  static from(...disposables) {
    return new Disposable(() => disposables.forEach(d => d.dispose()));
  }
}

// --- Simple data classes ---

class Position {
  constructor(line, character) { this.line = line; this.character = character; }
}

class Range {
  constructor(startLine, startChar, endLine, endChar) {
    if (startLine instanceof Position) {
      this.start = startLine; this.end = startChar;
    } else {
      this.start = new Position(startLine, startChar);
      this.end = new Position(endLine, endChar);
    }
  }
}

class Selection extends Range {
  constructor(anchorLine, anchorChar, activeLine, activeChar) {
    super(anchorLine, anchorChar, activeLine, activeChar);
    this.anchor = this.start;
    this.active = this.end;
  }
}

class RelativePattern {
  constructor(base, pattern) {
    this.baseUri = typeof base === "string" ? Uri.file(base) : (base.uri || base);
    this.base = typeof base === "string" ? base : (base.uri || base).fsPath;
    this.pattern = pattern;
  }
}

// --- Enums ---

const ViewColumn = { Active: -1, Beside: -2, One: 1, Two: 2, Three: 3, Four: 4, Five: 5, Six: 6, Seven: 7, Eight: 8, Nine: 9 };
const StatusBarAlignment = { Left: 1, Right: 2 };
const ConfigurationTarget = { Global: 1, Workspace: 2, WorkspaceFolder: 3 };
const ProgressLocation = { SourceControl: 1, Window: 10, Notification: 15 };
const UIKind = { Desktop: 1, Web: 2 };
const TextEditorRevealType = { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 };
const TextDocumentChangeReason = { Undo: 1, Redo: 2 };
const DiagnosticSeverity = { Error: 0, Warning: 1, Information: 2, Hint: 3 };
const FileType = { Unknown: 0, File: 1, Directory: 2, SymbolicLink: 64 };
const FileChangeType = { Changed: 1, Created: 2, Deleted: 3 };
const NotebookCellKind = { Markup: 1, Code: 2 };
const NotebookEditorRevealType = { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 };

// --- Tab types (for instanceof checks) ---

class TabInputText { constructor(uri) { this.uri = uri; } }
class TabInputTextDiff { constructor(original, modified) { this.original = original; this.modified = modified; } }
class TabInputWebview { constructor(viewType) { this.viewType = viewType; } }

// --- FileSystemError ---

class FileSystemError extends Error {
  constructor(messageOrUri) { super(typeof messageOrUri === "string" ? messageOrUri : messageOrUri?.toString()); this.code = "Unknown"; }
  static FileNotFound(uri) { const e = new FileSystemError(uri); e.code = "FileNotFound"; return e; }
  static FileExists(uri) { const e = new FileSystemError(uri); e.code = "FileExists"; return e; }
  static FileNotADirectory(uri) { const e = new FileSystemError(uri); e.code = "FileNotADirectory"; return e; }
  static FileIsADirectory(uri) { const e = new FileSystemError(uri); e.code = "FileIsADirectory"; return e; }
  static NoPermissions(uri) { const e = new FileSystemError(uri); e.code = "NoPermissions"; return e; }
  static Unavailable(uri) { const e = new FileSystemError(uri); e.code = "Unavailable"; return e; }
}

// --- Notebook stubs ---

class NotebookCellData { constructor(kind, value, languageId) { this.kind = kind; this.value = value; this.languageId = languageId; } }
class NotebookCellOutputItem {
  constructor(data, mime) { this.data = data; this.mime = mime; }
  static error(err) { return new NotebookCellOutputItem(Buffer.from(err.message), "application/vnd.code.notebook.error"); }
}
class NotebookEdit {
  static insertCells(index, cells) { return { index, cells, type: "insertCells" }; }
}
class NotebookRange { constructor(start, end) { this.start = start; this.end = end; } }

// --- WorkspaceEdit ---

class WorkspaceEdit { constructor() { this._edits = []; } set(uri, edits) { this._edits.push({ uri, edits }); } }

// --- CancellationToken stub ---

const CancellationTokenNone = { isCancellationRequested: false, onCancellationRequested: () => new Disposable(() => {}) };

module.exports = {
  Uri, EventEmitter, Disposable, Position, Range, Selection, RelativePattern,
  ViewColumn, StatusBarAlignment, ConfigurationTarget, ProgressLocation, UIKind,
  TextEditorRevealType, TextDocumentChangeReason, DiagnosticSeverity,
  FileType, FileChangeType, NotebookCellKind, NotebookEditorRevealType,
  FileSystemError, TabInputText, TabInputTextDiff, TabInputWebview,
  NotebookCellData, NotebookCellOutputItem, NotebookEdit, NotebookRange,
  WorkspaceEdit, CancellationTokenNone,
};
```

- [ ] **Step 4: Run tests**

```bash
node --test test/shim-unit.test.js
```

Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add Resources/vscode-shim/types.js test/shim-unit.test.js
git commit -m "feat(shim): add core types — Uri, EventEmitter, Disposable, enums"
```

---

## Task 3: ExtensionContext + globalState

**Files:**
- Create: `Resources/vscode-shim/context.js`
- Modify: `test/shim-unit.test.js`

- [ ] **Step 1: Write tests for globalState and ExtensionContext**

```js
// append to test/shim-unit.test.js
const { createExtensionContext } = require("../Resources/vscode-shim/context.js");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

describe("ExtensionContext", () => {
  let ctx;
  let tmpDir;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "hangar-test-"));
    ctx = createExtensionContext({
      extensionPath: "/fake/extension",
      storagePath: tmpDir,
    });
  });

  it("has extensionPath and extensionUri", () => {
    assert.strictEqual(ctx.extensionPath, "/fake/extension");
    assert.strictEqual(ctx.extensionUri.fsPath, "/fake/extension");
  });

  it("has extension.id", () => {
    assert.strictEqual(ctx.extension.id, "anthropic.claude-code");
  });

  it("globalState.get returns undefined for missing key", () => {
    assert.strictEqual(ctx.globalState.get("missing"), undefined);
  });

  it("globalState.get returns default for missing key", () => {
    assert.strictEqual(ctx.globalState.get("missing", 42), 42);
  });

  it("globalState.update and get round-trips", async () => {
    await ctx.globalState.update("foo", "bar");
    assert.strictEqual(ctx.globalState.get("foo"), "bar");
  });

  it("globalState persists to disk", async () => {
    await ctx.globalState.update("persist", true);
    // Create new context with same storage path
    const ctx2 = createExtensionContext({ extensionPath: "/fake", storagePath: tmpDir });
    assert.strictEqual(ctx2.globalState.get("persist"), true);
  });

  it("subscriptions is an array", () => {
    assert.ok(Array.isArray(ctx.subscriptions));
  });

  it("logUri points to logs directory", () => {
    assert.ok(ctx.logUri.fsPath.endsWith("/logs"));
  });
});
```

- [ ] **Step 2: Run test — fails**

```bash
node --test test/shim-unit.test.js
```

- [ ] **Step 3: Implement context.js**

```js
// Resources/vscode-shim/context.js
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { Uri, Disposable } = require("./types.js");

class Memento {
  constructor(filePath) {
    this._filePath = filePath;
    this._data = {};
    try {
      if (fs.existsSync(filePath)) {
        this._data = JSON.parse(fs.readFileSync(filePath, "utf-8"));
      }
    } catch { /* start fresh */ }
  }

  get(key, defaultValue) {
    return key in this._data ? this._data[key] : defaultValue;
  }

  async update(key, value) {
    if (value === undefined) {
      delete this._data[key];
    } else {
      this._data[key] = value;
    }
    const dir = path.dirname(this._filePath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(this._filePath, JSON.stringify(this._data, null, 2));
  }

  keys() { return Object.keys(this._data); }
}

function createExtensionContext({ extensionPath, storagePath }) {
  const globalStatePath = path.join(storagePath, "globalState.json");
  const logsPath = path.join(storagePath, "logs");

  return {
    subscriptions: [],
    extensionPath,
    extensionUri: Uri.file(extensionPath),
    globalState: new Memento(globalStatePath),
    logUri: Uri.file(logsPath),
    logPath: logsPath,
    extension: {
      id: "anthropic.claude-code",
      extensionUri: Uri.file(extensionPath),
      extensionPath,
      packageJSON: (() => {
        try {
          return JSON.parse(fs.readFileSync(path.join(extensionPath, "package.json"), "utf-8"));
        } catch { return {}; }
      })(),
    },
    // Stubs for properties we don't implement
    storageUri: Uri.file(storagePath),
    globalStorageUri: Uri.file(storagePath),
    storagePath,
    globalStoragePath: storagePath,
    extensionMode: 1, // Production
    environmentVariableCollection: { persistent: false, replace() {}, append() {}, prepend() {}, get() {}, forEach() {}, delete() {}, clear() {}, [Symbol.iterator]: function*() {} },
    secrets: { get: async () => undefined, store: async () => {}, delete: async () => {}, onDidChange: () => new Disposable(() => {}) },
  };
}

module.exports = { createExtensionContext, Memento };
```

- [ ] **Step 4: Run tests**

```bash
node --test test/shim-unit.test.js
```

Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add Resources/vscode-shim/context.js test/shim-unit.test.js
git commit -m "feat(shim): add ExtensionContext with JSON-backed globalState"
```

---

## Task 4: Commands Module

**Files:**
- Create: `Resources/vscode-shim/commands.js`
- Modify: `test/shim-unit.test.js`

- [ ] **Step 1: Write tests**

```js
// append to test/shim-unit.test.js
const { createCommands } = require("../Resources/vscode-shim/commands.js");

describe("commands", () => {
  let commands;

  beforeEach(() => {
    commands = createCommands();
  });

  it("registerCommand stores handler", () => {
    let called = false;
    commands.registerCommand("test.cmd", () => { called = true; });
    commands.executeCommand("test.cmd");
    assert.strictEqual(called, true);
  });

  it("executeCommand passes args", () => {
    let received;
    commands.registerCommand("test.args", (a, b) => { received = [a, b]; });
    commands.executeCommand("test.args", 1, 2);
    assert.deepStrictEqual(received, [1, 2]);
  });

  it("setContext stores in context map", () => {
    commands.executeCommand("setContext", "myKey", true);
    assert.strictEqual(commands.getContext("myKey"), true);
  });

  it("registerCommand returns disposable", () => {
    const d = commands.registerCommand("test.disp", () => {});
    assert.ok(typeof d.dispose === "function");
  });
});
```

- [ ] **Step 2: Run test — fails**

- [ ] **Step 3: Implement commands.js**

```js
// Resources/vscode-shim/commands.js
"use strict";

const { Disposable } = require("./types.js");

function createCommands() {
  const handlers = new Map();
  const contextValues = new Map();

  function registerCommand(id, handler) {
    handlers.set(id, handler);
    return new Disposable(() => handlers.delete(id));
  }

  async function executeCommand(id, ...args) {
    if (id === "setContext") {
      contextValues.set(args[0], args[1]);
      return;
    }
    const handler = handlers.get(id);
    if (handler) return handler(...args);
    // Unknown commands are silently ignored (many are VSCode-internal like workbench.action.*)
  }

  function getContext(key) {
    return contextValues.get(key);
  }

  return { registerCommand, executeCommand, getContext };
}

module.exports = { createCommands };
```

- [ ] **Step 4: Run tests — pass**

- [ ] **Step 5: Commit**

```bash
git add Resources/vscode-shim/commands.js test/shim-unit.test.js
git commit -m "feat(shim): add commands module with register/execute/setContext"
```

---

## Task 5: Workspace — Configuration, Folders, findFiles

**Files:**
- Create: `Resources/vscode-shim/workspace.js`
- Modify: `test/shim-unit.test.js`

- [ ] **Step 1: Write tests**

```js
// append to test/shim-unit.test.js
const { createWorkspace } = require("../Resources/vscode-shim/workspace.js");

describe("workspace", () => {
  let workspace;
  let tmpDir;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "hangar-ws-"));
    // Create some test files
    fs.writeFileSync(path.join(tmpDir, "foo.ts"), "");
    fs.writeFileSync(path.join(tmpDir, "bar.js"), "");
    fs.mkdirSync(path.join(tmpDir, "sub"));
    fs.writeFileSync(path.join(tmpDir, "sub", "baz.ts"), "");

    workspace = createWorkspace({
      cwd: tmpDir,
      settingsPath: path.join(tmpDir, ".settings.json"),
      extensionPackageJson: { contributes: { configuration: { properties: {
        "claudeCode.respectGitIgnore": { type: "boolean", default: true },
        "claudeCode.hideOnboarding": { type: "boolean", default: false },
      }}}},
    });
  });

  it("workspaceFolders returns cwd-based folder", () => {
    assert.strictEqual(workspace.workspaceFolders.length, 1);
    assert.strictEqual(workspace.workspaceFolders[0].uri.fsPath, tmpDir);
    assert.strictEqual(workspace.workspaceFolders[0].name, path.basename(tmpDir));
  });

  it("getConfiguration returns object with get()", () => {
    const config = workspace.getConfiguration("claudeCode");
    assert.strictEqual(config.get("respectGitIgnore"), true);
    assert.strictEqual(config.get("respectGitIgnore", false), true); // default from package.json, not the arg
  });

  it("getConfiguration.get returns arg default for unknown key", () => {
    const config = workspace.getConfiguration("claudeCode");
    assert.strictEqual(config.get("nonExistent", 42), 42);
  });

  it("getConfiguration.has checks existence", () => {
    const config = workspace.getConfiguration("claudeCode");
    assert.strictEqual(config.has("respectGitIgnore"), true);
    assert.strictEqual(config.has("nonExistent"), false);
  });

  it("getConfiguration.update persists", async () => {
    const config = workspace.getConfiguration("claudeCode");
    await config.update("hideOnboarding", true, 1);
    assert.strictEqual(config.get("hideOnboarding"), true);
  });

  it("getConfiguration.inspect returns layers", () => {
    const config = workspace.getConfiguration("claudeCode");
    const result = config.inspect("respectGitIgnore");
    assert.strictEqual(result.defaultValue, true);
  });

  it("asRelativePath works", () => {
    assert.strictEqual(workspace.asRelativePath(path.join(tmpDir, "foo.ts")), "foo.ts");
  });

  it("findFiles finds matching files", async () => {
    const results = await workspace.findFiles("**/*.ts");
    const names = results.map(u => path.basename(u.fsPath)).sort();
    assert.deepStrictEqual(names, ["baz.ts", "foo.ts"]);
  });
});
```

- [ ] **Step 2: Run test — fails**

- [ ] **Step 3: Implement workspace.js**

```js
// Resources/vscode-shim/workspace.js
"use strict";

const fs = require("node:fs");
const fsPromises = require("node:fs/promises");
const nodePath = require("node:path");
const { Uri, Disposable, EventEmitter, RelativePattern } = require("./types.js");

function createWorkspace({ cwd, settingsPath, extensionPackageJson }) {
  const configDefaults = {};
  const configProperties = extensionPackageJson?.contributes?.configuration?.properties || {};
  for (const [key, def] of Object.entries(configProperties)) {
    configDefaults[key] = def.default;
  }

  let userSettings = {};
  try {
    if (fs.existsSync(settingsPath)) {
      userSettings = JSON.parse(fs.readFileSync(settingsPath, "utf-8"));
    }
  } catch { /* fresh */ }

  function saveSettings() {
    const dir = nodePath.dirname(settingsPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(settingsPath, JSON.stringify(userSettings, null, 2));
  }

  const folder = {
    uri: Uri.file(cwd),
    name: nodePath.basename(cwd),
    index: 0,
  };

  function getConfiguration(section) {
    const prefix = section ? section + "." : "";

    return {
      get(key, defaultValue) {
        const fullKey = prefix + key;
        if (fullKey in userSettings) return userSettings[fullKey];
        if (fullKey in configDefaults) return configDefaults[fullKey];
        return defaultValue;
      },
      has(key) {
        const fullKey = prefix + key;
        return fullKey in userSettings || fullKey in configDefaults;
      },
      async update(key, value, _target) {
        const fullKey = prefix + key;
        userSettings[fullKey] = value;
        saveSettings();
      },
      inspect(key) {
        const fullKey = prefix + key;
        return {
          key: fullKey,
          defaultValue: configDefaults[fullKey],
          globalValue: userSettings[fullKey],
          workspaceValue: undefined,
          workspaceFolderValue: undefined,
        };
      },
    };
  }

  async function findFiles(pattern, _exclude, maxResults = 100) {
    const globPattern = typeof pattern === "string" ? pattern :
      (pattern instanceof RelativePattern ? pattern.pattern : String(pattern));

    const results = [];
    async function walk(dir, depth = 0) {
      if (depth > 10 || results.length >= maxResults) return;
      let entries;
      try { entries = await fsPromises.readdir(dir, { withFileTypes: true }); } catch { return; }
      for (const entry of entries) {
        if (results.length >= maxResults) break;
        const fullPath = nodePath.join(dir, entry.name);
        if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
        if (entry.isDirectory()) {
          await walk(fullPath, depth + 1);
        } else if (entry.isFile()) {
          if (matchGlob(globPattern, nodePath.relative(cwd, fullPath))) {
            results.push(Uri.file(fullPath));
          }
        }
      }
    }
    await walk(cwd);
    return results;
  }

  // Minimal glob matching: supports **, *, ?
  function matchGlob(pattern, filePath) {
    const regex = pattern
      .replace(/\./g, "\\.")
      .replace(/\*\*/g, "<<<GLOBSTAR>>>")
      .replace(/\*/g, "[^/]*")
      .replace(/<<<GLOBSTAR>>>/g, ".*")
      .replace(/\?/g, ".");
    return new RegExp("^" + regex + "$").test(filePath);
  }

  const noopEvent = () => new Disposable(() => {});

  return {
    workspaceFolders: [folder],
    getConfiguration,
    findFiles,
    asRelativePath(pathOrUri) {
      const p = typeof pathOrUri === "string" ? pathOrUri : pathOrUri.fsPath;
      return nodePath.relative(cwd, p);
    },
    getWorkspaceFolder(_uri) { return folder; },
    openTextDocument(uriOrOptions) {
      if (uriOrOptions && typeof uriOrOptions === "object" && "content" in uriOrOptions) {
        return Promise.resolve({
          uri: Uri.from({ scheme: "untitled", path: "" }),
          getText: () => uriOrOptions.content,
          languageId: uriOrOptions.language || "plaintext",
          lineCount: (uriOrOptions.content || "").split("\n").length,
          fileName: "",
          isUntitled: true,
          isDirty: false,
          isClosed: false,
          version: 1,
        });
      }
      return Promise.reject(new Error("openTextDocument(uri) not implemented in Hangar"));
    },
    applyEdit: () => Promise.resolve(false),
    textDocuments: [],
    workspaceFile: undefined,
    rootPath: cwd,
    fs: {
      stat: (uri) => fsPromises.stat(uri.fsPath).then(s => ({
        type: s.isFile() ? 1 : s.isDirectory() ? 2 : 0,
        ctime: s.ctimeMs, mtime: s.mtimeMs, size: s.size,
      })),
      readFile: (uri) => fsPromises.readFile(uri.fsPath),
      writeFile: (uri, content) => fsPromises.writeFile(uri.fsPath, content),
    },
    registerFileSystemProvider: () => new Disposable(() => {}),
    registerTextDocumentContentProvider: () => new Disposable(() => {}),
    onDidChangeTextDocument: noopEvent,
    onDidSaveTextDocument: noopEvent,
    onWillSaveTextDocument: noopEvent,
    onDidChangeConfiguration: noopEvent,
    onDidChangeWorkspaceFolders: noopEvent,
  };
}

module.exports = { createWorkspace };
```

- [ ] **Step 4: Run tests — pass**

- [ ] **Step 5: Commit**

```bash
git add Resources/vscode-shim/workspace.js test/shim-unit.test.js
git commit -m "feat(shim): add workspace with getConfiguration, findFiles, folders"
```

---

## Task 6: Window — Webview Bridge (the core)

**Files:**
- Create: `Resources/vscode-shim/window.js`
- Create: `Resources/vscode-shim/notifications.js`
- Modify: `test/shim-unit.test.js`

- [ ] **Step 1: Write tests for webview bridge**

```js
// append to test/shim-unit.test.js
const { createWindow } = require("../Resources/vscode-shim/window.js");
const protocol = require("../Resources/vscode-shim/protocol.js");

describe("window webview bridge", () => {
  let window;
  let written;

  beforeEach(() => {
    written = [];
    protocol._setWriter((data) => written.push(data));
    window = createWindow();
  });

  it("registerWebviewViewProvider stores provider", () => {
    const provider = { resolveWebviewView: () => {} };
    const disposable = window.registerWebviewViewProvider("testView", provider);
    assert.ok(typeof disposable.dispose === "function");
  });

  it("webview.postMessage writes to stdout", () => {
    const provider = {
      resolveWebviewView(view) {
        view.webview.postMessage({ type: "test", data: 123 });
      }
    };
    window.registerWebviewViewProvider("testView", provider);
    window._activateFirstProvider();

    assert.strictEqual(written.length, 1);
    const msg = JSON.parse(written[0]);
    assert.strictEqual(msg.type, "webview_message");
    assert.deepStrictEqual(msg.message, { type: "test", data: 123 });
  });

  it("webview.onDidReceiveMessage fires from stdin", () => {
    const received = [];
    const provider = {
      resolveWebviewView(view) {
        view.webview.onDidReceiveMessage((msg) => received.push(msg));
      }
    };
    window.registerWebviewViewProvider("testView", provider);
    window._activateFirstProvider();

    // Simulate stdin message
    window._handleWebviewMessage({ type: "io_message", channelId: "ch1" });
    assert.deepStrictEqual(received, [{ type: "io_message", channelId: "ch1" }]);
  });

  it("webview.asWebviewUri returns uri unchanged", () => {
    let result;
    const provider = {
      resolveWebviewView(view) {
        result = view.webview.asWebviewUri(Uri.file("/foo/bar"));
      }
    };
    window.registerWebviewViewProvider("testView", provider);
    window._activateFirstProvider();
    assert.strictEqual(result.fsPath, "/foo/bar");
  });
});
```

- [ ] **Step 2: Run test — fails**

- [ ] **Step 3: Implement window.js**

```js
// Resources/vscode-shim/window.js
"use strict";

const { EventEmitter, Disposable, Uri, ViewColumn, StatusBarAlignment, CancellationTokenNone } = require("./types.js");
const { writeStdout } = require("./protocol.js");
const { createNotificationHandler } = require("./notifications.js");

function createWindow() {
  const providers = new Map();
  const panels = [];
  let activeWebview = null;
  const notifications = createNotificationHandler();

  // --- Webview ---

  function createWebviewObject(extensionUri) {
    const onDidReceiveMessageEmitter = new EventEmitter();
    const onDidDisposeEmitter = new EventEmitter();
    const onDidChangeVisibilityEmitter = new EventEmitter();

    const webview = {
      postMessage(message) {
        writeStdout({ type: "webview_message", message });
        return Promise.resolve(true);
      },
      onDidReceiveMessage: onDidReceiveMessageEmitter.event,
      asWebviewUri(uri) { return uri; },
      cspSource: "",
      options: { enableScripts: true, localResourceRoots: [] },
      html: "",
      _onDidReceiveMessageEmitter: onDidReceiveMessageEmitter,
    };

    const view = {
      webview,
      visible: true,
      onDidChangeVisibility: onDidChangeVisibilityEmitter.event,
      onDidDispose: onDidDisposeEmitter.event,
      viewType: "",
      show() {},
      _onDidDisposeEmitter: onDidDisposeEmitter,
    };

    return view;
  }

  function registerWebviewViewProvider(viewType, provider, _options) {
    providers.set(viewType, provider);
    return new Disposable(() => providers.delete(viewType));
  }

  function createWebviewPanel(viewType, title, showOptions, _options) {
    const view = createWebviewObject(null);
    view.viewType = viewType;
    view.title = title;
    view.active = true;
    view.viewColumn = typeof showOptions === "number" ? showOptions : (showOptions?.viewColumn || ViewColumn.One);
    view.reveal = () => {};
    view.dispose = () => view._onDidDisposeEmitter.fire();
    view.onDidChangeViewState = () => new Disposable(() => {});
    panels.push(view);

    if (!activeWebview) {
      activeWebview = view;
    }

    return view;
  }

  function _activateFirstProvider() {
    for (const [viewType, provider] of providers) {
      const view = createWebviewObject(null);
      view.viewType = viewType;
      activeWebview = view;
      provider.resolveWebviewView(view, {}, CancellationTokenNone);
      break;
    }
  }

  function _handleWebviewMessage(message) {
    if (activeWebview) {
      activeWebview.webview._onDidReceiveMessageEmitter.fire(message);
    }
  }

  function _getActiveWebview() { return activeWebview; }

  // --- Stubs ---

  const noopEvent = () => new Disposable(() => {});

  return {
    registerWebviewViewProvider,
    createWebviewPanel,
    registerWebviewPanelSerializer: () => new Disposable(() => {}),
    registerUriHandler: () => new Disposable(() => {}),

    showInformationMessage: (...args) => notifications.show("info", ...args),
    showErrorMessage: (...args) => notifications.show("error", ...args),
    showWarningMessage: (...args) => notifications.show("warning", ...args),

    showTextDocument(doc, _options) {
      writeStdout({
        type: "show_document",
        content: typeof doc.getText === "function" ? doc.getText() : "",
        fileName: doc.fileName || doc.uri?.fsPath || "untitled",
        languageId: doc.languageId || "plaintext",
      });
      return Promise.resolve({});
    },

    showQuickPick: () => { process.stderr.write("[vscode-shim] STUB: showQuickPick\n"); return Promise.resolve(undefined); },
    showInputBox: () => { process.stderr.write("[vscode-shim] STUB: showInputBox\n"); return Promise.resolve(undefined); },
    withProgress(_opts, fn) { return fn({ report() {} }, CancellationTokenNone); },

    createStatusBarItem: () => ({ text: "", tooltip: "", command: "", alignment: 2, priority: 0, show() {}, hide() {}, dispose() {} }),
    createOutputChannel: (name) => ({
      name, append(s) { process.stderr.write(s); }, appendLine(s) { process.stderr.write(s + "\n"); },
      clear() {}, show() {}, hide() {}, dispose() {},
      info(s) { process.stderr.write(`[${name}:info] ${s}\n`); },
      warn(s) { process.stderr.write(`[${name}:warn] ${s}\n`); },
      error(s) { process.stderr.write(`[${name}:error] ${s}\n`); },
      debug(s) { process.stderr.write(`[${name}:debug] ${s}\n`); },
      trace(s) { process.stderr.write(`[${name}:trace] ${s}\n`); },
    }),
    createTerminal(opts) {
      writeStdout({
        type: "open_terminal",
        name: typeof opts === "string" ? opts : opts?.name || "Terminal",
        cwd: opts?.cwd,
        shellPath: opts?.shellPath,
      });
      return {
        name: typeof opts === "string" ? opts : opts?.name || "Terminal",
        sendText() {}, show() {}, hide() {}, dispose() {},
        shellIntegration: undefined,
      };
    },

    activeTextEditor: undefined,
    visibleTextEditors: [],
    terminals: [],
    activeTerminal: undefined,
    activeNotebookEditor: undefined,
    tabGroups: { all: [], activeTabGroup: { tabs: [], isActive: true, viewColumn: ViewColumn.One } },

    onDidChangeActiveTextEditor: noopEvent,
    onDidChangeVisibleTextEditors: noopEvent,
    onDidChangeTextEditorSelection: noopEvent,
    onDidStartTerminalShellExecution: noopEvent,
    onDidEndTerminalShellExecution: noopEvent,
    onDidChangeTerminalShellIntegration: noopEvent,

    // Internal methods for ShimProcess integration
    _activateFirstProvider,
    _handleWebviewMessage,
    _getActiveWebview,
    _handleNotificationResponse: (requestId, buttonValue) => notifications.handleResponse(requestId, buttonValue),
  };
}

module.exports = { createWindow };
```

- [ ] **Step 4: Implement notifications.js**

```js
// Resources/vscode-shim/notifications.js
"use strict";

const crypto = require("node:crypto");
const { writeStdout } = require("./protocol.js");

function createNotificationHandler() {
  const pending = new Map();

  function show(severity, message, ...rest) {
    // Separate options object from button strings
    const buttons = rest.filter(r => typeof r === "string");
    const requestId = crypto.randomUUID();

    return new Promise((resolve) => {
      // 60-second timeout
      const timer = setTimeout(() => {
        pending.delete(requestId);
        resolve(undefined);
      }, 60_000);

      pending.set(requestId, { resolve, timer });

      writeStdout({
        type: "show_notification",
        severity,
        message: String(message),
        buttons,
        requestId,
      });
    });
  }

  function handleResponse(requestId, buttonValue) {
    const entry = pending.get(requestId);
    if (!entry) return;
    pending.delete(requestId);
    clearTimeout(entry.timer);
    entry.resolve(buttonValue ?? undefined);
  }

  function rejectAll() {
    for (const [id, entry] of pending) {
      clearTimeout(entry.timer);
      entry.resolve(undefined);
    }
    pending.clear();
  }

  return { show, handleResponse, rejectAll };
}

module.exports = { createNotificationHandler };
```

- [ ] **Step 5: Run tests — pass**

```bash
node --test test/shim-unit.test.js
```

- [ ] **Step 6: Commit**

```bash
git add Resources/vscode-shim/window.js Resources/vscode-shim/notifications.js test/shim-unit.test.js
git commit -m "feat(shim): add window module with webview bridge and notifications"
```

---

## Task 7: Env Module

**Files:**
- Create: `Resources/vscode-shim/env.js`

- [ ] **Step 1: Implement env.js**

```js
// Resources/vscode-shim/env.js
"use strict";

const crypto = require("node:crypto");
const { Uri } = require("./types.js");
const { writeStdout } = require("./protocol.js");

function createEnv({ machineIdPath, remoteName }) {
  const fs = require("node:fs");
  const path = require("node:path");

  // machineId: persisted UUID
  let machineId;
  try {
    machineId = fs.readFileSync(machineIdPath, "utf-8").trim();
  } catch {
    machineId = crypto.randomUUID();
    const dir = path.dirname(machineIdPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(machineIdPath, machineId);
  }

  return {
    appName: "Visual Studio Code",
    appRoot: "",
    uiKind: 1, // Desktop
    language: "en",
    machineId,
    sessionId: crypto.randomUUID(),
    shell: process.env.SHELL || "/bin/zsh",
    remoteName: remoteName || undefined,
    clipboard: {
      readText: () => Promise.resolve(""),
      writeText: () => Promise.resolve(),
    },
    openExternal(uri) {
      const url = typeof uri === "string" ? uri : uri.toString();
      writeStdout({ type: "open_url", url });
      return Promise.resolve(true);
    },
  };
}

module.exports = { createEnv };
```

- [ ] **Step 2: Commit**

```bash
git add Resources/vscode-shim/env.js
git commit -m "feat(shim): add env module with appName, clipboard, openExternal"
```

---

## Task 8: Stubs + Proxy Assembly

**Files:**
- Create: `Resources/vscode-shim/stubs.js`

- [ ] **Step 1: Implement stubs.js — assembles all modules into the vscode shim with Proxy**

```js
// Resources/vscode-shim/stubs.js
"use strict";

const types = require("./types.js");
const { writeStdout } = require("./protocol.js");
const { Disposable } = types;

const warnedStubs = new Set();

function warnOnce(apiName) {
  if (warnedStubs.has(apiName)) return;
  warnedStubs.add(apiName);
  const msg = `Stub called: ${apiName}`;
  process.stderr.write(`[vscode-shim] WARN: ${msg}\n`);
  writeStdout({ type: "log", level: "warn", msg });
}

/**
 * Assemble the full vscode module from all sub-modules.
 * Wraps with Proxy for unknown API detection.
 */
function assembleVscodeModule({ window, workspace, commands, env }) {
  const knownApis = {
    // types
    ...types,

    // modules
    window,
    workspace,
    commands,
    env,

    // languages
    languages: {
      getDiagnostics: () => [],
      onDidChangeDiagnostics: () => new Disposable(() => {}),
    },

    // extensions
    extensions: {
      getExtension: () => undefined,
      all: [],
    },

    // version
    version: "1.100.0",
  };

  return new Proxy(knownApis, {
    get(target, prop) {
      if (prop in target) return target[prop];
      // Symbol properties (Symbol.toStringTag, etc.) should not warn
      if (typeof prop === "symbol") return undefined;
      const msg = `Unknown vscode API accessed: vscode.${String(prop)}`;
      process.stderr.write(`[vscode-shim] WARN: ${msg}\n`);
      writeStdout({ type: "log", level: "warn", msg });
      return undefined;
    },
  });
}

module.exports = { assembleVscodeModule, warnOnce };
```

- [ ] **Step 2: Commit**

```bash
git add Resources/vscode-shim/stubs.js
git commit -m "feat(shim): add stubs module with Proxy-based unknown API detection"
```

---

## Task 9: Main Entry — index.js

**Files:**
- Create: `Resources/vscode-shim/index.js`

- [ ] **Step 1: Implement index.js — the entry point that ties everything together**

```js
#!/usr/bin/env node
// Resources/vscode-shim/index.js
"use strict";

// === CRITICAL: Redirect console BEFORE anything else ===
console.log = (...args) => process.stderr.write("[ext:log] " + args.map(String).join(" ") + "\n");
console.warn = (...args) => process.stderr.write("[ext:warn] " + args.map(String).join(" ") + "\n");
console.error = (...args) => process.stderr.write("[ext:error] " + args.map(String).join(" ") + "\n");

const Module = require("node:module");
const path = require("node:path");
const fs = require("node:fs");

const { writeStdout, startStdinReader } = require("./protocol.js");
const { createExtensionContext } = require("./context.js");
const { createCommands } = require("./commands.js");
const { createWorkspace } = require("./workspace.js");
const { createWindow } = require("./window.js");
const { createEnv } = require("./env.js");
const { assembleVscodeModule } = require("./stubs.js");

// --- Parse CLI args ---

function parseArgs() {
  const args = process.argv.slice(2);
  const parsed = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--extension-path" && args[i + 1]) parsed.extensionPath = args[++i];
    else if (args[i] === "--cwd" && args[i + 1]) parsed.cwd = args[++i];
    else if (args[i] === "--resume" && args[i + 1]) parsed.resume = args[++i];
    else if (args[i] === "--permission-mode" && args[i + 1]) parsed.permissionMode = args[++i];
  }
  return parsed;
}

async function main() {
  const args = parseArgs();

  if (!args.extensionPath) {
    process.stderr.write("[vscode-shim] ERROR: --extension-path is required\n");
    process.exit(1);
  }
  if (!args.cwd) {
    process.stderr.write("[vscode-shim] ERROR: --cwd is required\n");
    process.exit(1);
  }

  // Resolve extension path (handle glob)
  let extensionPath = args.extensionPath;
  if (extensionPath.includes("*")) {
    const { globSync } = require("node:fs");
    // fallback: manual resolve
    const dir = path.dirname(extensionPath);
    const pattern = path.basename(extensionPath);
    try {
      const entries = fs.readdirSync(dir).filter(e => e.startsWith(pattern.replace("*", "")));
      if (entries.length > 0) {
        entries.sort();
        extensionPath = path.join(dir, entries[entries.length - 1]);
      }
    } catch {
      process.stderr.write(`[vscode-shim] ERROR: Cannot resolve extension path: ${extensionPath}\n`);
      process.exit(1);
    }
  }

  const extensionJsPath = path.join(extensionPath, "extension.js");
  if (!fs.existsSync(extensionJsPath)) {
    process.stderr.write(`[vscode-shim] ERROR: extension.js not found at ${extensionJsPath}\n`);
    process.exit(1);
  }

  // Read extension package.json
  let extensionPackageJson = {};
  try {
    extensionPackageJson = JSON.parse(fs.readFileSync(path.join(extensionPath, "package.json"), "utf-8"));
  } catch { /* ok */ }

  // Storage paths
  const storagePath = path.join(
    process.env.HOME || "~",
    "Library", "Application Support", "Hangar"
  );

  // --- Create vscode modules ---

  const commands = createCommands();
  const workspace = createWorkspace({
    cwd: args.cwd,
    settingsPath: path.join(storagePath, "settings.json"),
    extensionPackageJson,
  });
  const window = createWindow();
  const env = createEnv({
    machineIdPath: path.join(storagePath, "machineId"),
    remoteName: undefined,
  });

  const vscodeShim = assembleVscodeModule({ window, workspace, commands, env });

  // --- Intercept require("vscode") ---

  const SHIM_ID = "__vscode_shim__";
  const originalResolve = Module._resolveFilename;
  Module._resolveFilename = function (request, parent, ...rest) {
    if (request === "vscode") return SHIM_ID;
    return originalResolve.call(this, request, parent, ...rest);
  };
  Module._cache[SHIM_ID] = { id: SHIM_ID, filename: SHIM_ID, loaded: true, exports: vscodeShim };

  // --- Create ExtensionContext ---

  const context = createExtensionContext({
    extensionPath,
    storagePath,
  });

  // --- Setup stdin handler ---

  let webviewReady = false;
  const stdinBuffer = [];

  startStdinReader((msg) => {
    if (msg.type === "webview_ready") {
      webviewReady = true;
      // Flush any buffered messages (none expected, but safety)
      return;
    }
    if (msg.type === "webview_message") {
      window._handleWebviewMessage(msg.message);
      return;
    }
    if (msg.type === "notification_response") {
      window._handleNotificationResponse(msg.requestId, msg.buttonValue);
      return;
    }
    process.stderr.write(`[vscode-shim] Unknown stdin message type: ${msg.type}\n`);
  });

  // --- Process cleanup ---

  process.on("exit", () => {
    try { process.kill(-process.pid, "SIGTERM"); } catch { /* ignore */ }
  });

  process.on("SIGTERM", () => process.exit(0));
  process.on("SIGINT", () => process.exit(0));

  // --- Load and activate extension ---

  process.stderr.write(`[vscode-shim] Loading extension from ${extensionPath}\n`);
  process.stderr.write(`[vscode-shim] CWD: ${args.cwd}\n`);

  // Change to extension directory so relative requires work
  const originalCwd = process.cwd();
  process.chdir(extensionPath);

  try {
    const extension = require(extensionJsPath);
    const result = extension.activate(context);
    if (result && typeof result.then === "function") {
      await result;
    }
  } catch (err) {
    writeStdout({
      type: "error",
      message: `activate() failed: ${err.message}`,
      stack: err.stack,
    });
    process.exit(1);
  }

  // Restore CWD
  process.chdir(originalCwd);

  // Activate the first webview provider (sidebar)
  window._activateFirstProvider();

  // Signal ready
  writeStdout({ type: "ready" });
  process.stderr.write("[vscode-shim] Ready.\n");
}

main().catch((err) => {
  process.stderr.write(`[vscode-shim] Fatal: ${err.message}\n${err.stack}\n`);
  writeStdout({ type: "error", message: err.message, stack: err.stack });
  process.exit(1);
});
```

- [ ] **Step 2: Test manual startup (smoke test)**

```bash
node Resources/vscode-shim/index.js \
  --extension-path ~/.vscode/extensions/anthropic.claude-code-2.1.87-darwin-arm64 \
  --cwd /tmp
```

Expected: stderr shows loading messages, stdout receives `{"type":"ready"}`, process keeps running. Ctrl+C to exit.

- [ ] **Step 3: Commit**

```bash
git add Resources/vscode-shim/index.js
git commit -m "feat(shim): add main entry with Module hook, activate, stdin routing"
```

---

## Task 10: Test Harness + Level 2 Integration Tests

**Files:**
- Create: `test/helpers.js`
- Create: `test/shim-integration.test.js`

- [ ] **Step 1: Implement test harness**

```js
// test/helpers.js
"use strict";

const { spawn } = require("node:child_process");
const readline = require("node:readline");
const path = require("node:path");
const fs = require("node:fs");

function findExtensionPath() {
  const dir = path.join(process.env.HOME, ".vscode", "extensions");
  const entries = fs.readdirSync(dir).filter(e => e.startsWith("anthropic.claude-code-")).sort();
  if (entries.length === 0) throw new Error("CC extension not found");
  return path.join(dir, entries[entries.length - 1]);
}

function spawnShim(opts = {}) {
  const proc = spawn("node", [
    path.join(__dirname, "..", "Resources", "vscode-shim", "index.js"),
    "--extension-path", opts.extensionPath || findExtensionPath(),
    "--cwd", opts.cwd || "/tmp",
    ...(opts.resume ? ["--resume", opts.resume] : []),
    ...(opts.permissionMode ? ["--permission-mode", opts.permissionMode] : []),
  ], { stdio: ["pipe", "pipe", "pipe"] });

  const stdoutRl = readline.createInterface({ input: proc.stdout });
  const stderrRl = readline.createInterface({ input: proc.stderr });
  const messages = [];
  const errors = [];

  stdoutRl.on("line", (line) => {
    try { messages.push(JSON.parse(line)); } catch { /* skip */ }
  });
  stderrRl.on("line", (line) => errors.push(line));

  function send(msg) {
    proc.stdin.write(JSON.stringify(msg) + "\n");
  }

  function waitFor(type, timeout = 30000) {
    return new Promise((resolve, reject) => {
      const start = Date.now();
      const check = () => {
        const idx = messages.findIndex(m => m.type === type);
        if (idx >= 0) {
          const msg = messages[idx];
          messages.splice(idx, 1);
          return resolve(msg);
        }
        if (Date.now() - start > timeout) {
          return reject(new Error(`Timeout (${timeout}ms) waiting for "${type}". Got: ${messages.map(m=>m.type).join(", ")}`));
        }
        setTimeout(check, 50);
      };
      check();
    });
  }

  function waitForWebviewResponse(requestId, timeout = 30000) {
    return new Promise((resolve, reject) => {
      const start = Date.now();
      const check = () => {
        const idx = messages.findIndex(m =>
          m.type === "webview_message" &&
          m.message?.type === "response" &&
          m.message?.requestId === requestId
        );
        if (idx >= 0) {
          const msg = messages[idx];
          messages.splice(idx, 1);
          return resolve(msg.message);
        }
        if (Date.now() - start > timeout) {
          return reject(new Error(`Timeout waiting for response to ${requestId}`));
        }
        setTimeout(check, 50);
      };
      check();
    });
  }

  function sendRequest(requestType, payload = {}, channelId = "ch1") {
    const requestId = `test-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
    send({
      type: "webview_message",
      message: {
        type: "request",
        channelId,
        requestId,
        request: { type: requestType, ...payload },
      },
    });
    return requestId;
  }

  function kill() {
    proc.kill("SIGTERM");
  }

  return { proc, messages, errors, send, waitFor, waitForWebviewResponse, sendRequest, kill };
}

module.exports = { spawnShim, findExtensionPath };
```

- [ ] **Step 2: Write integration tests**

```js
// test/shim-integration.test.js
"use strict";

const assert = require("node:assert");
const { describe, it, afterEach } = require("node:test");
const { spawnShim } = require("./helpers.js");

let shim;

afterEach(() => { if (shim) { shim.kill(); shim = null; } });

describe("Level 2: Integration", () => {
  it("starts and sends ready", async () => {
    shim = spawnShim();
    const ready = await shim.waitFor("ready", 60000);
    assert.strictEqual(ready.type, "ready");
  });

  it("responds to init request", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.send({ type: "webview_ready" });

    const reqId = shim.sendRequest("init");
    const response = await shim.waitForWebviewResponse(reqId, 15000);
    assert.strictEqual(response.response.type || response.type, response.type);
    // init should return some config — exact shape depends on extension version
  });

  it("responds to get_asset_uris", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.send({ type: "webview_ready" });

    const reqId = shim.sendRequest("get_asset_uris");
    const response = await shim.waitForWebviewResponse(reqId, 10000);
    assert.ok(response);
  });

  it("survives unknown message type", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.send({ type: "webview_message", message: { type: "totally_unknown_type_xyz" } });
    // Should not crash — wait a bit and verify process is alive
    await new Promise(r => setTimeout(r, 1000));
    assert.strictEqual(shim.proc.exitCode, null, "Process should still be running");
  });

  it("survives invalid JSON on stdin", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.proc.stdin.write("not valid json\n");
    await new Promise(r => setTimeout(r, 1000));
    assert.strictEqual(shim.proc.exitCode, null, "Process should still be running");
  });

  it("exits cleanly on SIGTERM", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.proc.kill("SIGTERM");
    await new Promise((resolve) => shim.proc.on("exit", resolve));
    assert.ok(true, "Process exited");
    shim = null; // already dead
  });
});
```

- [ ] **Step 3: Run integration tests**

```bash
node --test test/shim-integration.test.js
```

Expected: Most tests pass. Some may need iteration depending on extension behavior.

- [ ] **Step 4: Commit**

```bash
git add test/helpers.js test/shim-integration.test.js
git commit -m "test(shim): add test harness and Level 2 integration tests"
```

---

## Task 11: ShimProcess.swift

**Files:**
- Create: `Sources/Hangar/ShimProcess.swift`
- Create: `Sources/Hangar/NodeDiscovery.swift`

- [ ] **Step 1: Implement NodeDiscovery.swift**

```swift
// Sources/Hangar/NodeDiscovery.swift
import Foundation
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "NodeDiscovery")

enum NodeDiscovery {
    struct NodeInfo {
        let path: String
        let version: String
    }

    static func find() -> NodeInfo? {
        let candidates = candidatePaths()
        for candidate in candidates {
            if let info = validate(path: candidate) {
                logger.info("Using Node.js: \(info.path) (v\(info.version))")
                return info
            }
        }
        logger.error("Node.js not found")
        return nil
    }

    private static func candidatePaths() -> [String] {
        var paths: [String] = []

        // 1. which node
        if let whichResult = shell("which node") {
            paths.append(whichResult)
        }

        // 2. Common locations
        paths.append(contentsOf: [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ])

        // 3. mise
        if let miseResult = shell("mise which node") {
            paths.append(miseResult)
        }

        // 4. nvm
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmDir = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            let sorted = entries.sorted()
            if let latest = sorted.last {
                paths.append("\(nvmDir)/\(latest)/bin/node")
            }
        }

        return paths.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func validate(path: String) -> NodeInfo? {
        guard let version = shell("\(path) --version") else { return nil }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("v") else { return nil }

        // Parse major version, require >= 18
        let parts = trimmed.dropFirst().split(separator: ".")
        guard let major = Int(parts.first ?? "0"), major >= 18 else {
            logger.warning("Node.js at \(path) is v\(trimmed) — need >= 18")
            return nil
        }

        return NodeInfo(path: path, version: String(trimmed.dropFirst()))
    }

    private static func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Implement ShimProcess.swift**

```swift
// Sources/Hangar/ShimProcess.swift
import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: "sh.saqoo.Hangar", category: "ShimProcess")

final class ShimProcess: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var isReady = false
    private var isWebViewReady = false
    private var pendingMessages: [[String: Any]] = []
    private var stdoutBuffer = Data()

    private let writeQueue = DispatchQueue(label: "sh.saqoo.Hangar.shimWrite")

    let workingDirectory: URL
    var resumeSessionId: String?
    var permissionMode: PermissionMode

    init(workingDirectory: URL, resumeSessionId: String? = nil, permissionMode: PermissionMode = .acceptEdits) {
        self.workingDirectory = workingDirectory
        self.resumeSessionId = resumeSessionId
        self.permissionMode = permissionMode
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard let nodeInfo = NodeDiscovery.find() else {
            logger.error("Cannot start shim: Node.js not found")
            return
        }

        guard let shimPath = Bundle.main.path(forResource: "vscode-shim/index", ofType: "js") else {
            logger.error("Cannot find vscode-shim/index.js in bundle")
            return
        }

        let extensionPath = CCExtension.extensionPath ?? ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodeInfo.path)

        var args = [shimPath, "--extension-path", extensionPath, "--cwd", workingDirectory.path]
        if let sessionId = resumeSessionId {
            args.append(contentsOf: ["--resume", sessionId])
        }
        args.append(contentsOf: ["--permission-mode", permissionMode.rawValue])
        proc.arguments = args

        // Environment
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        // Read stdout (line-buffered)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStdoutData(data)
        }

        // Read stderr (for logging)
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            for line in str.split(separator: "\n") {
                logger.info("[shim:stderr] \(line, privacy: .public)")
            }
        }

        // Termination handler
        proc.terminationHandler = { [weak self] process in
            logger.info("Shim process exited with status \(process.terminationStatus)")
            DispatchQueue.main.async {
                self?.handleProcessExit(status: process.terminationStatus)
            }
        }

        do {
            try proc.run()
            logger.info("Shim process started: PID \(proc.processIdentifier)")
        } catch {
            logger.error("Failed to start shim: \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminate()
        cleanupOrphans()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let dict = message.body as? [String: Any] else { return }
        sendToShim(["type": "webview_message", "message": dict])
    }

    // MARK: - WebView Ready

    func webViewDidFinishLoad() {
        isWebViewReady = true
        sendToShim(["type": "webview_ready"])
    }

    // MARK: - Private

    private func handleStdoutData(_ data: Data) {
        stdoutBuffer.append(data)

        // Split on newlines, process complete lines
        while let range = stdoutBuffer.range(of: Data("\n".utf8)) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty,
                  let jsonData = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = msg["type"] as? String
            else { continue }

            DispatchQueue.main.async { [weak self] in
                self?.handleShimMessage(type: type, msg: msg)
            }
        }
    }

    private func handleShimMessage(type: String, msg: [String: Any]) {
        switch type {
        case "ready":
            isReady = true
            // Flush pending messages
            for pending in pendingMessages {
                writeToStdin(pending)
            }
            pendingMessages.removeAll()

        case "webview_message":
            guard let innerMessage = msg["message"] else { return }
            sendToWebView(innerMessage)

        case "show_document":
            if let content = msg["content"] as? String {
                let fileName = msg["fileName"] as? String ?? "output"
                ContentViewer.show(content: content, title: fileName, in: webView)
            }

        case "show_notification":
            handleNotification(msg)

        case "open_url":
            if let urlStr = msg["url"] as? String, let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }

        case "open_terminal":
            if let name = msg["name"] as? String {
                // Open Terminal.app with claude command
                let script = "tell application \"Terminal\" to do script \"cd \(workingDirectory.path) && claude\""
                NSAppleScript(source: script)?.executeAndReturnError(nil)
            }

        case "log":
            let level = msg["level"] as? String ?? "info"
            let message = msg["msg"] as? String ?? ""
            logger.info("[shim:\(level, privacy: .public)] \(message, privacy: .public)")

        case "error":
            let message = msg["message"] as? String ?? "Unknown error"
            logger.error("[shim] \(message, privacy: .public)")

        default:
            logger.info("[shim] Unknown message type: \(type, privacy: .public)")
        }
    }

    private func handleNotification(_ msg: [String: Any]) {
        guard let message = msg["message"] as? String,
              let requestId = msg["requestId"] as? String
        else { return }

        let severity = msg["severity"] as? String ?? "info"
        let buttons = msg["buttons"] as? [String] ?? []

        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.messageText = message
            switch severity {
            case "error": alert.alertStyle = .critical
            case "warning": alert.alertStyle = .warning
            default: alert.alertStyle = .informational
            }
            for button in buttons {
                alert.addButton(withTitle: button)
            }
            alert.addButton(withTitle: "Dismiss")

            let response = alert.runModal()
            let buttonIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            let buttonValue: Any
            if buttonIndex < buttons.count {
                buttonValue = buttons[buttonIndex]
            } else {
                buttonValue = NSNull()
            }

            self?.sendToShim([
                "type": "notification_response",
                "requestId": requestId,
                "buttonValue": buttonValue,
            ])
        }
    }

    private func sendToShim(_ msg: [String: Any]) {
        if !isReady && msg["type"] as? String != "webview_ready" {
            pendingMessages.append(msg)
            return
        }
        writeToStdin(msg)
    }

    private func writeToStdin(_ msg: [String: Any]) {
        writeQueue.async { [weak self] in
            guard let data = try? JSONSerialization.data(withJSONObject: msg),
                  var str = String(data: data, encoding: .utf8)
            else { return }
            str += "\n"
            self?.stdinPipe?.fileHandleForWriting.write(str.data(using: .utf8)!)
        }
    }

    private func sendToWebView(_ message: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let jsonStr = String(data: data, encoding: .utf8)
        else { return }

        let js = "window.postMessage({type:'from-extension',message:\(jsonStr)},'*')"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func handleProcessExit(status: Int32) {
        cleanupOrphans()
        if status != 0 {
            logger.error("Shim process crashed with status \(status)")
            // TODO: Show restart banner in webview
        }
    }

    private func cleanupOrphans() {
        guard let pid = process?.processIdentifier, pid > 0 else { return }
        // Find children of the Node.js process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            if let childPid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                kill(childPid, SIGTERM)
                logger.info("Sent SIGTERM to orphan PID \(childPid)")
            }
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Hangar/ShimProcess.swift Sources/Hangar/NodeDiscovery.swift
git commit -m "feat(swift): add ShimProcess and NodeDiscovery for Node.js subprocess management"
```

---

## Task 12: Integrate ShimProcess with WebViewContainer + Feature Flag

**Files:**
- Modify: `Sources/Hangar/AppState.swift`
- Modify: `Sources/Hangar/WebViewContainer.swift`
- Modify: `Sources/Hangar/HangarApp.swift`

- [ ] **Step 1: Add useShim flag to AppState**

Add a `useShim` property to `AppState.swift`:

```swift
// In AppState.swift, add:
@Published var useShim = false
```

- [ ] **Step 2: Modify WebViewContainer to support ShimProcess alongside existing handler**

In `WebViewContainer.swift`, add conditional initialization. When `useShim` is true, create a `ShimProcess` instead of `WebViewMessageHandler`. Wire up `webViewDidFinishLoad()` callback from WKNavigationDelegate.

The key changes:
- Add `shimProcess: ShimProcess?` property
- In `makeNSView`, if `useShim`, create ShimProcess and register as script message handler
- In WKNavigationDelegate's `didFinish`, call `shimProcess?.webViewDidFinishLoad()`

- [ ] **Step 3: Add menu toggle in HangarApp**

Add a Debug menu item "Use VSCode Shim" that toggles `appState.useShim`. This allows switching between old and new implementations at runtime (requires restarting the session).

- [ ] **Step 4: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme Hangar -configuration Debug -derivedDataPath build build
```

Expected: Builds without errors. Both old and new code paths compile.

- [ ] **Step 5: Commit**

```bash
git add Sources/Hangar/AppState.swift Sources/Hangar/WebViewContainer.swift Sources/Hangar/HangarApp.swift
git commit -m "feat(swift): integrate ShimProcess with feature flag toggle"
```

---

## Task 13: Bundle vscode-shim in Xcode Project

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add vscode-shim resources to project.yml**

Add the `Resources/vscode-shim/` directory as a resource bundle in `project.yml` so it gets included in the app bundle.

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate && xcodebuild -scheme Hangar -configuration Debug -derivedDataPath build build
```

- [ ] **Step 3: Verify bundle contains shim**

```bash
ls build/Build/Products/Debug/Hangar.app/Contents/Resources/vscode-shim/
```

Expected: `index.js`, `protocol.js`, `types.js`, `context.js`, `commands.js`, `workspace.js`, `window.js`, `notifications.js`, `env.js`, `stubs.js`

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "build: bundle vscode-shim resources in Xcode project"
```

---

## Task 14: Manual Smoke Test + Fix Iteration

- [ ] **Step 1: Launch Hangar with shim mode**

1. Build and launch Hangar
2. Enable "Use VSCode Shim" from Debug menu
3. Select a directory and start a new session
4. Verify the chat UI loads
5. Send a test message "Hello"
6. Verify streaming response appears

- [ ] **Step 2: Fix issues found during smoke test**

Iterate on any issues. Common problems:
- Ready handshake timing
- Message format mismatches
- Missing API stubs (Proxy warnings in stderr)

- [ ] **Step 3: Run Level 2 integration tests**

```bash
node --test test/shim-integration.test.js
```

Fix any failures.

- [ ] **Step 4: Commit fixes**

```bash
git add -A
git commit -m "fix(shim): address smoke test findings"
```

---

## Task 15: Cleanup — Remove Old Implementation

Only after Task 14 confirms the shim works.

- [ ] **Step 1: Delete old files**

```bash
git rm Sources/Hangar/WebViewMessageHandler.swift
git rm Sources/Hangar/ClaudeProcess.swift
```

- [ ] **Step 2: Remove feature flag, make shim the default**

Update `AppState.swift` to remove `useShim` flag. Update `WebViewContainer.swift` to always use `ShimProcess`. Remove Debug menu toggle from `HangarApp.swift`.

- [ ] **Step 3: Build and verify**

```bash
xcodegen generate && xcodebuild -scheme Hangar -configuration Debug -derivedDataPath build build
```

- [ ] **Step 4: Run all tests**

```bash
node --test test/shim-unit.test.js
node --test test/shim-integration.test.js
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: remove WebViewMessageHandler and ClaudeProcess, shim is default

Deletes 1796 lines of Swift protocol reimplementation.
The vscode-shim now handles all extension communication."
```

---

## Summary

| Task | Description | Key Files |
|------|------------|-----------|
| 1 | NDJSON protocol layer | `protocol.js` |
| 2 | Core types (Uri, EventEmitter, enums) | `types.js` |
| 3 | ExtensionContext + globalState | `context.js` |
| 4 | Commands module | `commands.js` |
| 5 | Workspace (config, folders, findFiles) | `workspace.js` |
| 6 | Window (webview bridge + notifications) | `window.js`, `notifications.js` |
| 7 | Env module | `env.js` |
| 8 | Stubs + Proxy assembly | `stubs.js` |
| 9 | Main entry (Module hook, activate) | `index.js` |
| 10 | Test harness + integration tests | `test/helpers.js`, `test/shim-integration.test.js` |
| 11 | ShimProcess.swift + NodeDiscovery | Swift subprocess manager |
| 12 | Feature flag integration | WebViewContainer, AppState, HangarApp |
| 13 | Bundle in Xcode project | project.yml |
| 14 | Smoke test + iteration | Manual testing |
| 15 | Cleanup old implementation | Delete WebViewMessageHandler + ClaudeProcess |
