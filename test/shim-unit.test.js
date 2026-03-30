"use strict";

const { describe, it, beforeEach } = require("node:test");
const assert = require("node:assert/strict");
const { Readable } = require("node:stream");

const { writeStdout, startStdinReader, _setWriter } = require("../Resources/vscode-shim/protocol.js");

describe("writeStdout", () => {
  it("writes JSON + newline", () => {
    let captured = "";
    _setWriter((data) => { captured += data; });

    writeStdout({ type: "hello", value: 42 });

    assert.equal(captured, '{"type":"hello","value":42}\n');
  });

  it("handles nested objects", () => {
    let captured = "";
    _setWriter((data) => { captured += data; });

    writeStdout({ a: { b: { c: [1, 2, 3] } } });

    assert.equal(captured, '{"a":{"b":{"c":[1,2,3]}}}\n');
  });
});

describe("startStdinReader", () => {
  it("parses valid JSON", async () => {
    const received = [];
    const input = new Readable({ read() {} });

    const rl = startStdinReader((msg) => { received.push(msg); }, input);

    input.push('{"type":"test","n":1}\n');
    input.push('{"type":"test","n":2}\n');
    input.push(null);

    await new Promise((resolve) => rl.on("close", resolve));

    assert.equal(received.length, 2);
    assert.deepEqual(received[0], { type: "test", n: 1 });
    assert.deepEqual(received[1], { type: "test", n: 2 });
  });

  it("skips invalid JSON lines", async () => {
    const received = [];
    const input = new Readable({ read() {} });

    // Capture stderr to verify warning
    const stderrChunks = [];
    const origStderrWrite = process.stderr.write;
    process.stderr.write = (chunk) => { stderrChunks.push(chunk); return true; };

    const rl = startStdinReader((msg) => { received.push(msg); }, input);

    input.push('not json at all\n');
    input.push('{"valid":true}\n');
    input.push('also {broken\n');
    input.push(null);

    await new Promise((resolve) => rl.on("close", resolve));

    // Restore stderr
    process.stderr.write = origStderrWrite;

    assert.equal(received.length, 1);
    assert.deepEqual(received[0], { valid: true });
    assert.equal(stderrChunks.length, 2);
    assert.match(stderrChunks[0], /Invalid JSON/);
  });
});

// ===========================================================================
// types.js tests
// ===========================================================================
const {
  Uri,
  EventEmitter,
  Disposable,
  Position,
  Range,
  Selection,
  RelativePattern,
  ViewColumn,
  StatusBarAlignment,
  ConfigurationTarget,
  ProgressLocation,
  UIKind,
  FileType,
  FileChangeType,
  DiagnosticSeverity,
  TabInputText,
  TabInputTextDiff,
  TabInputWebview,
  FileSystemError,
  NotebookCellData,
  NotebookCellKind,
  NotebookEdit,
  NotebookRange,
  WorkspaceEdit,
  CancellationTokenNone,
} = require("../Resources/vscode-shim/types.js");

const nodePath = require("node:path");

describe("Uri", () => {
  it("Uri.file creates file URI", () => {
    const uri = Uri.file("/Users/test/file.txt");
    assert.equal(uri.scheme, "file");
    assert.equal(uri.path, "/Users/test/file.txt");
    assert.equal(uri.fsPath, "/Users/test/file.txt");
  });

  it("Uri.file resolves relative paths", () => {
    const uri = Uri.file("relative/path.txt");
    assert.equal(uri.scheme, "file");
    assert.equal(uri.path, nodePath.resolve("relative/path.txt"));
  });

  it("Uri.joinPath appends segments", () => {
    const base = Uri.file("/Users/test");
    const joined = Uri.joinPath(base, "sub", "file.txt");
    assert.equal(joined.scheme, "file");
    assert.equal(joined.path, "/Users/test/sub/file.txt");
  });

  it("Uri.parse handles file URIs", () => {
    const uri = Uri.parse("file:///Users/test/file.txt");
    assert.equal(uri.scheme, "file");
    assert.equal(uri.path, "/Users/test/file.txt");
    assert.equal(uri.fsPath, "/Users/test/file.txt");
  });

  it("Uri.parse handles http URIs", () => {
    const uri = Uri.parse("https://example.com/path?q=1#frag");
    assert.equal(uri.scheme, "https");
    assert.equal(uri.authority, "example.com");
    assert.equal(uri.path, "/path");
    assert.equal(uri.query, "q=1");
    assert.equal(uri.fragment, "frag");
  });

  it("Uri.from creates URI from components", () => {
    const uri = Uri.from({ scheme: "https", authority: "example.com", path: "/api" });
    assert.equal(uri.scheme, "https");
    assert.equal(uri.authority, "example.com");
    assert.equal(uri.path, "/api");
  });

  it("Uri.toString produces string", () => {
    const uri = Uri.parse("https://example.com/path?q=1#frag");
    assert.equal(uri.toString(), "https://example.com/path?q=1#frag");
  });

  it("Uri.toJSON serializes correctly", () => {
    const uri = Uri.file("/test/path");
    const json = uri.toJSON();
    assert.equal(json.scheme, "file");
    assert.equal(json.fsPath, "/test/path");
    assert.equal(json.path, "/test/path");
  });

  it("Uri.with returns new Uri with changed properties", () => {
    const base = Uri.from({ scheme: "https", authority: "example.com", path: "/old" });
    const changed = base.with({ path: "/new" });
    assert.equal(changed.path, "/new");
    assert.equal(changed.scheme, "https");
    assert.equal(base.path, "/old"); // original unchanged
  });
});

describe("EventEmitter", () => {
  it("fire calls listeners", () => {
    const emitter = new EventEmitter();
    const received = [];
    emitter.event((data) => received.push(data));

    emitter.fire("hello");
    emitter.fire("world");

    assert.deepEqual(received, ["hello", "world"]);
  });

  it("event returns disposable that removes listener", () => {
    const emitter = new EventEmitter();
    const received = [];
    const disposable = emitter.event((data) => received.push(data));

    emitter.fire("before");
    disposable.dispose();
    emitter.fire("after");

    assert.deepEqual(received, ["before"]);
  });

  it("dispose removes all listeners", () => {
    const emitter = new EventEmitter();
    const received = [];
    emitter.event((data) => received.push(data));
    emitter.event((data) => received.push(data));

    emitter.fire("before");
    emitter.dispose();
    emitter.fire("after");

    assert.deepEqual(received, ["before", "before"]);
  });
});

describe("Disposable", () => {
  it("calls callback on dispose", () => {
    let called = false;
    const d = new Disposable(() => { called = true; });
    assert.equal(called, false);
    d.dispose();
    assert.equal(called, true);
  });

  it("calls callback only once", () => {
    let count = 0;
    const d = new Disposable(() => { count++; });
    d.dispose();
    d.dispose();
    assert.equal(count, 1);
  });

  it("Disposable.from creates composite disposable", () => {
    let a = false, b = false;
    const d = Disposable.from(
      new Disposable(() => { a = true; }),
      new Disposable(() => { b = true; }),
    );
    d.dispose();
    assert.equal(a, true);
    assert.equal(b, true);
  });
});

describe("Position and Range", () => {
  it("Position stores line and character", () => {
    const p = new Position(10, 5);
    assert.equal(p.line, 10);
    assert.equal(p.character, 5);
  });

  it("Range from line/char numbers", () => {
    const r = new Range(1, 2, 3, 4);
    assert.equal(r.start.line, 1);
    assert.equal(r.start.character, 2);
    assert.equal(r.end.line, 3);
    assert.equal(r.end.character, 4);
  });

  it("Range from Position objects", () => {
    const start = new Position(1, 2);
    const end = new Position(3, 4);
    const r = new Range(start, end);
    assert.equal(r.start.line, 1);
    assert.equal(r.end.character, 4);
  });
});

describe("Selection", () => {
  it("has anchor and active", () => {
    const s = new Selection(1, 2, 3, 4);
    assert.equal(s.anchor.line, 1);
    assert.equal(s.anchor.character, 2);
    assert.equal(s.active.line, 3);
    assert.equal(s.active.character, 4);
    assert.equal(s.start.line, 1);
  });
});

describe("Enums", () => {
  it("ViewColumn has expected values", () => {
    assert.equal(ViewColumn.Active, -1);
    assert.equal(ViewColumn.Beside, -2);
    assert.equal(ViewColumn.One, 1);
    assert.equal(ViewColumn.Nine, 9);
  });

  it("StatusBarAlignment", () => {
    assert.equal(StatusBarAlignment.Left, 1);
    assert.equal(StatusBarAlignment.Right, 2);
  });

  it("ConfigurationTarget", () => {
    assert.equal(ConfigurationTarget.Global, 1);
    assert.equal(ConfigurationTarget.WorkspaceFolder, 3);
  });

  it("ProgressLocation", () => {
    assert.equal(ProgressLocation.Notification, 15);
  });

  it("UIKind", () => {
    assert.equal(UIKind.Desktop, 1);
    assert.equal(UIKind.Web, 2);
  });

  it("DiagnosticSeverity", () => {
    assert.equal(DiagnosticSeverity.Error, 0);
    assert.equal(DiagnosticSeverity.Hint, 3);
  });

  it("FileType", () => {
    assert.equal(FileType.Unknown, 0);
    assert.equal(FileType.SymbolicLink, 64);
  });

  it("FileChangeType", () => {
    assert.equal(FileChangeType.Changed, 1);
    assert.equal(FileChangeType.Deleted, 3);
  });
});

describe("Tab types", () => {
  it("TabInputText stores uri", () => {
    const uri = Uri.file("/test.txt");
    const tab = new TabInputText(uri);
    assert.equal(tab.uri, uri);
    assert.ok(tab instanceof TabInputText);
  });

  it("TabInputTextDiff stores original and modified", () => {
    const orig = Uri.file("/a.txt");
    const mod = Uri.file("/b.txt");
    const tab = new TabInputTextDiff(orig, mod);
    assert.equal(tab.original, orig);
    assert.equal(tab.modified, mod);
  });

  it("TabInputWebview stores viewType", () => {
    const tab = new TabInputWebview("myView");
    assert.equal(tab.viewType, "myView");
  });
});

describe("FileSystemError", () => {
  it("extends Error", () => {
    const err = FileSystemError.FileNotFound("/test");
    assert.ok(err instanceof Error);
    assert.ok(err instanceof FileSystemError);
    assert.match(err.message, /File not found/);
  });

  it("has static factory methods", () => {
    assert.ok(FileSystemError.FileExists("x") instanceof FileSystemError);
    assert.ok(FileSystemError.FileNotADirectory("x") instanceof FileSystemError);
    assert.ok(FileSystemError.FileIsADirectory("x") instanceof FileSystemError);
    assert.ok(FileSystemError.NoPermissions("x") instanceof FileSystemError);
    assert.ok(FileSystemError.Unavailable("x") instanceof FileSystemError);
  });
});

describe("Notebook stubs", () => {
  it("NotebookCellData stores kind, value, languageId", () => {
    const cell = new NotebookCellData(NotebookCellKind.Code, "print(1)", "python");
    assert.equal(cell.kind, 2);
    assert.equal(cell.value, "print(1)");
    assert.equal(cell.languageId, "python");
  });

  it("NotebookEdit.insertCells creates edit", () => {
    const edit = NotebookEdit.insertCells(0, []);
    assert.equal(edit.index, 0);
    assert.deepEqual(edit.cells, []);
  });

  it("NotebookRange stores start and end", () => {
    const r = new NotebookRange(0, 5);
    assert.equal(r.start, 0);
    assert.equal(r.end, 5);
  });
});

describe("WorkspaceEdit", () => {
  it("stores edits by uri", () => {
    const ws = new WorkspaceEdit();
    const uri = Uri.file("/test.txt");
    ws.set(uri, [{ text: "hello" }]);
    assert.deepEqual(ws._edits.get(uri), [{ text: "hello" }]);
  });
});

describe("CancellationTokenNone", () => {
  it("is not cancelled", () => {
    assert.equal(CancellationTokenNone.isCancellationRequested, false);
  });

  it("onCancellationRequested returns disposable", () => {
    const d = CancellationTokenNone.onCancellationRequested();
    assert.equal(typeof d.dispose, "function");
  });
});

describe("RelativePattern", () => {
  it("creates from string base", () => {
    const rp = new RelativePattern("/Users/test", "**/*.ts");
    assert.equal(rp.pattern, "**/*.ts");
    assert.equal(rp.base, "/Users/test");
    assert.ok(rp.baseUri instanceof Uri);
  });

  it("creates from Uri base", () => {
    const uri = Uri.file("/Users/test");
    const rp = new RelativePattern(uri, "*.js");
    assert.equal(rp.pattern, "*.js");
    assert.equal(rp.baseUri, uri);
  });
});

// ===========================================================================
// context.js tests
// ===========================================================================
const { createExtensionContext } = require("../Resources/vscode-shim/context.js");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

describe("ExtensionContext", () => {
  let ctx, tmpDir;
  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "canopy-test-"));
    ctx = createExtensionContext({ extensionPath: "/fake/ext", storagePath: tmpDir });
  });

  it("has extensionPath and extensionUri", () => {
    assert.equal(ctx.extensionPath, "/fake/ext");
    assert.equal(ctx.extensionUri.scheme, "file");
    assert.equal(ctx.extensionUri.fsPath, "/fake/ext");
  });

  it("has extension.id", () => {
    assert.equal(ctx.extension.id, "anthropic.claude-code");
    assert.equal(ctx.extension.extensionPath, "/fake/ext");
    assert.equal(ctx.extension.extensionUri.fsPath, "/fake/ext");
  });

  it("globalState.get returns undefined for missing key", () => {
    assert.equal(ctx.globalState.get("nonexistent"), undefined);
  });

  it("globalState.get returns default for missing key", () => {
    assert.equal(ctx.globalState.get("nonexistent", 42), 42);
  });

  it("globalState.update and get round-trips", () => {
    ctx.globalState.update("hello", "world");
    assert.equal(ctx.globalState.get("hello"), "world");

    ctx.globalState.update("obj", { a: 1 });
    assert.deepEqual(ctx.globalState.get("obj"), { a: 1 });

    // Delete via undefined
    ctx.globalState.update("hello", undefined);
    assert.equal(ctx.globalState.get("hello"), undefined);
    assert.ok(!ctx.globalState.keys().includes("hello"));
  });

  it("globalState persists to disk", () => {
    ctx.globalState.update("persist", "yes");

    const filePath = path.join(tmpDir, "globalState.json");
    const raw = fs.readFileSync(filePath, "utf-8");
    const data = JSON.parse(raw);
    assert.equal(data.persist, "yes");

    // New Memento instance reads from same file
    const ctx2 = createExtensionContext({ extensionPath: "/fake/ext", storagePath: tmpDir });
    assert.equal(ctx2.globalState.get("persist"), "yes");
  });

  it("subscriptions is an array", () => {
    assert.ok(Array.isArray(ctx.subscriptions));
    assert.equal(ctx.subscriptions.length, 0);
  });

  it("logUri points to logs directory", () => {
    assert.equal(ctx.logUri.scheme, "file");
    assert.ok(ctx.logUri.fsPath.endsWith("/logs"));
    assert.ok(ctx.logPath.endsWith("/logs"));
  });
});

// ===========================================================================
// commands.js tests
// ===========================================================================
const { createCommands } = require("../Resources/vscode-shim/commands.js");

describe("commands", () => {
  it("registerCommand stores and executes handler", async () => {
    const cmds = createCommands();
    let called = false;
    cmds.registerCommand("myCmd", () => { called = true; });
    await cmds.executeCommand("myCmd");
    assert.equal(called, true);
  });

  it("executeCommand passes args", async () => {
    const cmds = createCommands();
    let received;
    cmds.registerCommand("sum", (a, b) => { received = a + b; return received; });
    const result = await cmds.executeCommand("sum", 3, 7);
    assert.equal(received, 10);
    assert.equal(result, 10);
  });

  it("setContext stores in context map", async () => {
    const cmds = createCommands();
    await cmds.executeCommand("setContext", "myKey", "myValue");
    assert.equal(cmds.getContext("myKey"), "myValue");
  });

  it("registerCommand returns disposable that unregisters", async () => {
    const cmds = createCommands();
    let count = 0;
    const disposable = cmds.registerCommand("counter", () => { count++; });
    await cmds.executeCommand("counter");
    assert.equal(count, 1);

    disposable.dispose();
    await cmds.executeCommand("counter");
    assert.equal(count, 1); // handler was removed, count stays at 1
  });

  it("executeCommand with unknown id does not throw", async () => {
    const cmds = createCommands();
    const result = await cmds.executeCommand("nonexistent.command", 1, 2, 3);
    assert.equal(result, undefined);
  });
});

// ===========================================================================
// workspace.js tests
// ===========================================================================
const { createWorkspace } = require("../Resources/vscode-shim/workspace.js");

describe("workspace", () => {
  let tmpDir, ws;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "canopy-ws-test-"));
    const settingsPath = path.join(tmpDir, "settings.json");
    const extensionPackageJson = {
      contributes: {
        configuration: {
          properties: {
            "myExt.fontSize": { default: 14, type: "number" },
            "myExt.theme": { default: "dark", type: "string" },
          },
        },
      },
    };
    ws = createWorkspace({ cwd: tmpDir, settingsPath, extensionPackageJson });
  });

  it("workspaceFolders returns cwd-based folder", () => {
    assert.equal(ws.workspaceFolders.length, 1);
    const folder = ws.workspaceFolders[0];
    assert.equal(folder.uri.fsPath, tmpDir);
    assert.equal(folder.name, path.basename(tmpDir));
    assert.equal(folder.index, 0);
  });

  it("getConfiguration returns default from package.json", () => {
    const config = ws.getConfiguration("myExt");
    assert.equal(config.get("fontSize"), 14);
    assert.equal(config.get("theme"), "dark");
  });

  it("getConfiguration.get returns arg default for unknown key", () => {
    const config = ws.getConfiguration("myExt");
    assert.equal(config.get("unknown", 99), 99);
    assert.equal(config.get("unknown"), undefined);
  });

  it("getConfiguration.has checks existence", () => {
    const config = ws.getConfiguration("myExt");
    assert.equal(config.has("fontSize"), true);
    assert.equal(config.has("nonexistent"), false);
  });

  it("getConfiguration.update persists", () => {
    const config = ws.getConfiguration("myExt");
    config.update("fontSize", 20);

    // Re-read to confirm persistence
    const config2 = ws.getConfiguration("myExt");
    assert.equal(config2.get("fontSize"), 20);
  });

  it("getConfiguration.inspect returns layers", () => {
    const config = ws.getConfiguration("myExt");
    config.update("fontSize", 20);

    const info = ws.getConfiguration("myExt").inspect("fontSize");
    assert.equal(info.key, "myExt.fontSize");
    assert.equal(info.defaultValue, 14);
    assert.equal(info.globalValue, 20);
    assert.equal(info.workspaceValue, undefined);
    assert.equal(info.workspaceFolderValue, undefined);
  });

  it("asRelativePath works", () => {
    const abs = path.join(tmpDir, "src", "index.ts");
    assert.equal(ws.asRelativePath(abs), path.join("src", "index.ts"));

    // Also works with Uri
    const uri = Uri.file(abs);
    assert.equal(ws.asRelativePath(uri), path.join("src", "index.ts"));
  });

  it("findFiles finds matching files", async () => {
    // Create test files
    fs.writeFileSync(path.join(tmpDir, "foo.ts"), "");
    fs.writeFileSync(path.join(tmpDir, "bar.js"), "");
    fs.mkdirSync(path.join(tmpDir, "sub"));
    fs.writeFileSync(path.join(tmpDir, "sub", "baz.ts"), "");

    const results = await ws.findFiles("**/*.ts");
    const fsPaths = results.map((u) => u.fsPath).sort();

    assert.equal(results.length, 2);
    assert.ok(fsPaths.includes(path.join(tmpDir, "foo.ts")));
    assert.ok(fsPaths.includes(path.join(tmpDir, "sub", "baz.ts")));
  });

  it("openTextDocument with content returns virtual doc", async () => {
    const doc = await ws.openTextDocument({ content: "hello world", language: "markdown" });
    assert.equal(doc.getText(), "hello world");
    assert.equal(doc.languageId, "markdown");
    assert.equal(doc.isUntitled, true);
  });

  it("applyEdit returns false", async () => {
    const result = await ws.applyEdit({});
    assert.equal(result, false);
  });

  it("rootPath returns cwd", () => {
    assert.equal(ws.rootPath, tmpDir);
  });

  it("getWorkspaceFolder returns the single folder", () => {
    const folder = ws.getWorkspaceFolder(Uri.file(path.join(tmpDir, "any.txt")));
    assert.equal(folder.uri.fsPath, tmpDir);
  });

  it("textDocuments is empty array", () => {
    assert.deepEqual(ws.textDocuments, []);
  });

  it("workspaceFile is undefined", () => {
    assert.equal(ws.workspaceFile, undefined);
  });

  it("registerFileSystemProvider returns Disposable", () => {
    const d = ws.registerFileSystemProvider("scheme", {});
    assert.equal(typeof d.dispose, "function");
  });

  it("registerTextDocumentContentProvider returns Disposable", () => {
    const d = ws.registerTextDocumentContentProvider("scheme", {});
    assert.equal(typeof d.dispose, "function");
  });

  it("onDidChangeConfiguration returns Disposable", () => {
    const d = ws.onDidChangeConfiguration(() => {});
    assert.equal(typeof d.dispose, "function");
  });

  it("fs.stat wraps node stat", async () => {
    const testFile = path.join(tmpDir, "stattest.txt");
    fs.writeFileSync(testFile, "data");
    const stat = await ws.fs.stat(Uri.file(testFile));
    assert.ok(stat.size > 0);
  });

  it("fs.readFile returns Uint8Array", async () => {
    const testFile = path.join(tmpDir, "readtest.txt");
    fs.writeFileSync(testFile, "content");
    const data = await ws.fs.readFile(Uri.file(testFile));
    assert.ok(data instanceof Uint8Array);
    assert.equal(Buffer.from(data).toString(), "content");
  });

  it("fs.writeFile writes data", async () => {
    const testFile = path.join(tmpDir, "writetest.txt");
    await ws.fs.writeFile(Uri.file(testFile), Buffer.from("written"));
    const content = fs.readFileSync(testFile, "utf-8");
    assert.equal(content, "written");
  });

  // --- Canopy settings layer tests ---

  it("getConfiguration reads Canopy settings with highest priority", () => {
    // Write user settings with one value
    const settingsPath = path.join(tmpDir, "settings.json");
    fs.writeFileSync(settingsPath, JSON.stringify({ "myExt.fontSize": 20 }));

    // Write Canopy settings with a different value (should win)
    const canopySettingsPath = path.join(tmpDir, "canopy-settings.json");
    fs.writeFileSync(canopySettingsPath, JSON.stringify({ "myExt.fontSize": 32 }));

    const ws2 = createWorkspace({
      cwd: tmpDir,
      settingsPath,
      extensionPackageJson: {
        contributes: {
          configuration: {
            properties: {
              "myExt.fontSize": { default: 14, type: "number" },
            },
          },
        },
      },
      canopySettingsPath,
    });

    const config = ws2.getConfiguration("myExt");
    assert.equal(config.get("fontSize"), 32); // Canopy settings wins
  });

  it("getConfiguration falls through when Canopy settings has no value", () => {
    // Write user settings with one value
    const settingsPath = path.join(tmpDir, "settings.json");
    fs.writeFileSync(settingsPath, JSON.stringify({ "myExt.fontSize": 20 }));

    // Canopy settings has a different key, not fontSize
    const canopySettingsPath = path.join(tmpDir, "canopy-settings.json");
    fs.writeFileSync(canopySettingsPath, JSON.stringify({ "myExt.theme": "canopy-light" }));

    const ws2 = createWorkspace({
      cwd: tmpDir,
      settingsPath,
      extensionPackageJson: {
        contributes: {
          configuration: {
            properties: {
              "myExt.fontSize": { default: 14, type: "number" },
              "myExt.theme": { default: "dark", type: "string" },
            },
          },
        },
      },
      canopySettingsPath,
    });

    const config = ws2.getConfiguration("myExt");
    // fontSize falls through to user settings (Canopy settings doesn't have it)
    assert.equal(config.get("fontSize"), 20);
    // theme comes from Canopy settings
    assert.equal(config.get("theme"), "canopy-light");
  });

  it("inspect() includes Canopy settings as globalValue", () => {
    const settingsPath = path.join(tmpDir, "settings.json");
    fs.writeFileSync(settingsPath, JSON.stringify({ "myExt.fontSize": 20 }));

    const canopySettingsPath = path.join(tmpDir, "canopy-settings.json");
    fs.writeFileSync(canopySettingsPath, JSON.stringify({ "myExt.fontSize": 32 }));

    const ws2 = createWorkspace({
      cwd: tmpDir,
      settingsPath,
      extensionPackageJson: {
        contributes: {
          configuration: {
            properties: {
              "myExt.fontSize": { default: 14, type: "number" },
            },
          },
        },
      },
      canopySettingsPath,
    });

    const info = ws2.getConfiguration("myExt").inspect("fontSize");
    assert.equal(info.key, "myExt.fontSize");
    assert.equal(info.defaultValue, 14);
    assert.equal(info.globalValue, 32); // Canopy settings as globalValue
    assert.equal(info.workspaceValue, 20); // User/workspace settings as workspaceValue
    assert.equal(info.workspaceFolderValue, undefined);
  });

  it("inspect() returns workspaceValue even when Canopy settings has no key", () => {
    const settingsPath = path.join(tmpDir, "settings.json");
    fs.writeFileSync(settingsPath, JSON.stringify({ "myExt.fontSize": 20 }));

    const canopySettingsPath = path.join(tmpDir, "canopy-settings.json");
    fs.writeFileSync(canopySettingsPath, JSON.stringify({}));

    const ws2 = createWorkspace({
      cwd: tmpDir,
      settingsPath,
      canopySettingsPath,
      extensionPackageJson: {},
    });

    const info = ws2.getConfiguration("myExt").inspect("fontSize");
    assert.equal(info.globalValue, 20); // falls through to user settings
    assert.equal(info.workspaceValue, undefined); // no canopy key → user stays in globalValue
  });
});

// ===========================================================================
// window.js + notifications.js tests
// ===========================================================================
const { createWindow } = require("../Resources/vscode-shim/window.js");
const { createNotificationHandler } = require("../Resources/vscode-shim/notifications.js");

describe("window webview bridge", () => {
  let win, stdout;

  beforeEach(() => {
    stdout = [];
    _setWriter((data) => { stdout.push(data); });
    win = createWindow();
  });

  it("registerWebviewViewProvider stores provider", () => {
    const provider = { resolveWebviewView() {} };
    const disposable = win.registerWebviewViewProvider("test.view", provider);
    assert.equal(typeof disposable.dispose, "function");
  });

  it("webview.postMessage writes to stdout", async () => {
    // Activate a provider so we have an active webview
    const provider = {
      resolveWebviewView(view, _ctx, _token) {
        // provider receives the view
      },
    };
    win.registerWebviewViewProvider("test.view", provider);
    win._activateFirstProvider();

    const webview = win._getActiveWebview();
    assert.ok(webview);

    await webview.postMessage({ type: "hello", data: 42 });

    const parsed = JSON.parse(stdout[stdout.length - 1].replace(/\n$/, ""));
    assert.equal(parsed.type, "webview_message");
    assert.deepEqual(parsed.message, { type: "hello", data: 42 });
  });

  it("webview.onDidReceiveMessage fires from _handleWebviewMessage", () => {
    const provider = {
      resolveWebviewView(_view, _ctx, _token) {},
    };
    win.registerWebviewViewProvider("test.view", provider);
    win._activateFirstProvider();

    const received = [];
    const webview = win._getActiveWebview();
    webview.onDidReceiveMessage((msg) => received.push(msg));

    win._handleWebviewMessage({ action: "click" });
    win._handleWebviewMessage({ action: "type" });

    assert.equal(received.length, 2);
    assert.deepEqual(received[0], { action: "click" });
    assert.deepEqual(received[1], { action: "type" });
  });

  it("webview.asWebviewUri returns uri unchanged", () => {
    win.registerWebviewViewProvider("test.view", { resolveWebviewView() {} });
    win._activateFirstProvider();

    const webview = win._getActiveWebview();
    const uri = Uri.file("/some/path");
    assert.equal(webview.asWebviewUri(uri), uri);
  });

  it("showTextDocument writes show_document to stdout", async () => {
    const doc = {
      getText() { return "console.log('hello');"; },
      fileName: "/test/file.js",
      languageId: "javascript",
    };

    await win.showTextDocument(doc);

    const parsed = JSON.parse(stdout[stdout.length - 1].replace(/\n$/, ""));
    assert.equal(parsed.type, "show_document");
    assert.equal(parsed.content, "console.log('hello');");
    assert.equal(parsed.fileName, "/test/file.js");
    assert.equal(parsed.languageId, "javascript");
  });

  it("createTerminal writes open_terminal to stdout", () => {
    const term = win.createTerminal({ name: "my-term" });

    const parsed = JSON.parse(stdout[stdout.length - 1].replace(/\n$/, ""));
    assert.equal(parsed.type, "open_terminal");
    assert.equal(parsed.name, "my-term");
    assert.equal(term.name, "my-term");
    assert.equal(typeof term.dispose, "function");
  });
});

describe("notifications", () => {
  let handler, stdout;

  beforeEach(() => {
    stdout = [];
    _setWriter((data) => { stdout.push(data); });
    handler = createNotificationHandler();
  });

  it("show writes show_notification to stdout", () => {
    handler.show("info", "Hello world", "OK", "Cancel");

    assert.equal(stdout.length, 1);
    const parsed = JSON.parse(stdout[0].replace(/\n$/, ""));
    assert.equal(parsed.type, "show_notification");
    assert.equal(parsed.severity, "info");
    assert.equal(parsed.message, "Hello world");
    assert.deepEqual(parsed.buttons, ["OK", "Cancel"]);
    assert.ok(parsed.requestId);
  });

  it("handleResponse resolves the promise", async () => {
    // Grab the requestId from stdout
    const promise = handler.show("error", "Fail?", "Retry", "Abort");
    const parsed = JSON.parse(stdout[0].replace(/\n$/, ""));

    handler.handleResponse(parsed.requestId, "Retry");

    const result = await promise;
    assert.equal(result, "Retry");
  });

  it("rejectAll resolves all pending as undefined", async () => {
    const p1 = handler.show("info", "msg1", "OK");
    const p2 = handler.show("warning", "msg2", "Yes");

    handler.rejectAll();

    const [r1, r2] = await Promise.all([p1, p2]);
    assert.equal(r1, undefined);
    assert.equal(r2, undefined);
  });
});

// ===========================================================================
// env.js tests
// ===========================================================================
const { createEnv } = require("../Resources/vscode-shim/env.js");

describe("env", () => {
  let tmpDir;

  beforeEach(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "canopy-env-test-"));
  });

  it("has appName as Visual Studio Code", () => {
    const env = createEnv({ machineIdPath: path.join(tmpDir, "machineId") });
    assert.equal(env.appName, "Visual Studio Code");
  });

  it("machineId persists to file", () => {
    const machineIdPath = path.join(tmpDir, "machineId");
    const env1 = createEnv({ machineIdPath });
    assert.ok(env1.machineId);
    assert.ok(fs.existsSync(machineIdPath));

    // Second call reads from file — same machineId
    const env2 = createEnv({ machineIdPath });
    assert.equal(env2.machineId, env1.machineId);
  });

  it("sessionId is a UUID", () => {
    const env = createEnv({ machineIdPath: path.join(tmpDir, "machineId") });
    // UUID v4 format: 8-4-4-4-12 hex chars
    assert.match(env.sessionId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  });

  it("openExternal writes open_url to stdout", async () => {
    const stdout = [];
    _setWriter((data) => { stdout.push(data); });

    const env = createEnv({ machineIdPath: path.join(tmpDir, "machineId") });
    const result = await env.openExternal("https://example.com");

    assert.equal(result, true);
    const parsed = JSON.parse(stdout[stdout.length - 1].replace(/\n$/, ""));
    assert.equal(parsed.type, "open_url");
    assert.equal(parsed.url, "https://example.com");
  });

  it("openExternal handles Uri objects", async () => {
    const stdout = [];
    _setWriter((data) => { stdout.push(data); });

    const env = createEnv({ machineIdPath: path.join(tmpDir, "machineId") });
    const uri = Uri.parse("https://example.com/path");
    await env.openExternal(uri);

    const parsed = JSON.parse(stdout[stdout.length - 1].replace(/\n$/, ""));
    assert.equal(parsed.url, "https://example.com/path");
  });

  it("machineId creates parent directory if needed", () => {
    const machineIdPath = path.join(tmpDir, "sub", "dir", "machineId");
    const env = createEnv({ machineIdPath });
    assert.ok(env.machineId);
    assert.ok(fs.existsSync(machineIdPath));
  });

  it("clipboard readText returns empty string", async () => {
    const env = createEnv({ machineIdPath: path.join(tmpDir, "machineId") });
    const text = await env.clipboard.readText();
    assert.equal(text, "");
  });

  it("has expected properties", () => {
    const env = createEnv({ machineIdPath: path.join(tmpDir, "machineId") });
    assert.equal(env.uiKind, 1);
    assert.equal(env.language, "en");
    assert.equal(env.appRoot, "");
    assert.equal(typeof env.shell, "string");
  });
});

// ===========================================================================
// stubs.js tests
// ===========================================================================
const { assembleVscodeModule } = require("../Resources/vscode-shim/stubs.js");

describe("assembleVscodeModule", () => {
  it("contains all expected namespaces", () => {
    const mockWindow = { name: "window" };
    const mockWorkspace = { name: "workspace" };
    const mockCommands = { name: "commands" };
    const mockEnv = { name: "env" };

    const vscode = assembleVscodeModule({
      window: mockWindow,
      workspace: mockWorkspace,
      commands: mockCommands,
      env: mockEnv,
    });

    assert.equal(vscode.window, mockWindow);
    assert.equal(vscode.workspace, mockWorkspace);
    assert.equal(vscode.commands, mockCommands);
    assert.equal(vscode.env, mockEnv);
    assert.equal(vscode.version, "1.100.0");
    // Types should be spread in
    assert.equal(vscode.Uri, Uri);
    assert.equal(typeof vscode.EventEmitter, "function");
    assert.equal(typeof vscode.Disposable, "function");
    // Languages and extensions stubs
    assert.ok(vscode.languages);
    assert.deepEqual(vscode.languages.getDiagnostics(), []);
    assert.ok(vscode.extensions);
    assert.equal(vscode.extensions.getExtension(), undefined);
    assert.deepEqual(vscode.extensions.all, []);
  });

  it("Proxy warns on unknown API access", () => {
    const stderrChunks = [];
    const origStderrWrite = process.stderr.write;
    process.stderr.write = (chunk) => { stderrChunks.push(chunk); return true; };

    const stdout = [];
    _setWriter((data) => { stdout.push(data); });

    const vscode = assembleVscodeModule({
      window: {},
      workspace: {},
      commands: {},
      env: {},
    });

    const result = vscode.nonExistentApi;
    process.stderr.write = origStderrWrite;

    assert.equal(result, undefined);
    assert.ok(stderrChunks.some((c) => c.includes("nonExistentApi")));
    const logMsg = JSON.parse(stdout[stdout.length - 1].replace(/\n$/, ""));
    assert.equal(logMsg.type, "log");
    assert.equal(logMsg.level, "warn");
    assert.ok(logMsg.msg.includes("nonExistentApi"));
  });

  it("Proxy returns undefined for symbol properties without warning", () => {
    const stderrChunks = [];
    const origStderrWrite = process.stderr.write;
    process.stderr.write = (chunk) => { stderrChunks.push(chunk); return true; };

    const vscode = assembleVscodeModule({
      window: {},
      workspace: {},
      commands: {},
      env: {},
    });

    const result = vscode[Symbol.iterator];
    process.stderr.write = origStderrWrite;

    assert.equal(result, undefined);
    // No warning for symbol access
    assert.equal(stderrChunks.length, 0);
  });
});
