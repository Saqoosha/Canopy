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
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "hangar-test-"));
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
