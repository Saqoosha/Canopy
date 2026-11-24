"use strict";

const path = require("node:path");

// ---------------------------------------------------------------------------
// Uri
// ---------------------------------------------------------------------------
class Uri {
  constructor(scheme, authority, fsPath, query, fragment) {
    this.scheme = scheme || "";
    this.authority = authority || "";
    this.path = fsPath || "";
    this.query = query || "";
    this.fragment = fragment || "";
  }

  get fsPath() {
    if (this.scheme === "file") {
      // On Windows authority is the UNC host; on posix it's empty
      return this.authority ? `//${this.authority}${this.path}` : this.path;
    }
    return this.path;
  }

  with(change) {
    return new Uri(
      change.scheme !== undefined ? change.scheme : this.scheme,
      change.authority !== undefined ? change.authority : this.authority,
      change.path !== undefined ? change.path : this.path,
      change.query !== undefined ? change.query : this.query,
      change.fragment !== undefined ? change.fragment : this.fragment,
    );
  }

  toString() {
    let result = "";
    if (this.scheme) {
      result += this.scheme + "://";
    }
    if (this.authority) {
      result += this.authority;
    }
    result += this.path;
    if (this.query) {
      result += "?" + this.query;
    }
    if (this.fragment) {
      result += "#" + this.fragment;
    }
    return result;
  }

  toJSON() {
    return {
      scheme: this.scheme,
      authority: this.authority,
      path: this.path,
      query: this.query,
      fragment: this.fragment,
      fsPath: this.fsPath,
    };
  }

  static file(fsPath) {
    const resolved = path.resolve(fsPath);
    return new Uri("file", "", resolved, "", "");
  }

  static joinPath(base, ...segments) {
    const joined = path.join(base.path, ...segments);
    return base.with({ path: joined });
  }

  static parse(value) {
    // Handle file:// URIs
    const fileMatch = value.match(/^file:\/\/(.*)/);
    if (fileMatch) {
      return new Uri("file", "", fileMatch[1], "", "");
    }
    // Handle scheme://authority/path?query#fragment
    const match = value.match(/^([a-zA-Z][a-zA-Z0-9+\-.]*):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/);
    if (match) {
      return new Uri(
        match[1],
        match[2],
        match[3] || "",
        match[4] ? match[4].slice(1) : "",
        match[5] ? match[5].slice(1) : "",
      );
    }
    // Fallback: treat whole thing as path
    return new Uri("", "", value, "", "");
  }

  static from({ scheme, authority, path: p, query, fragment }) {
    return new Uri(scheme || "", authority || "", p || "", query || "", fragment || "");
  }
}

// ---------------------------------------------------------------------------
// EventEmitter
// ---------------------------------------------------------------------------
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
      try {
        listener(data);
      } catch (err) {
        let details;
        try {
          details = err && err.stack ? err.stack : String(err);
        } catch {
          details = "<unstringifiable thrown value>";
        }
        try {
          process.stderr.write(`[shim:EventEmitter] listener threw: ${details}\n`);
        } catch {
          // keep emitter resilient even if stderr is unavailable
        }
      }
    }
  }

  dispose() {
    this._listeners.length = 0;
  }
}

// ---------------------------------------------------------------------------
// Disposable
// ---------------------------------------------------------------------------
class Disposable {
  constructor(callOnDispose) {
    this._callOnDispose = callOnDispose;
    this._disposed = false;
  }

  dispose() {
    if (!this._disposed) {
      this._disposed = true;
      if (this._callOnDispose) this._callOnDispose();
    }
  }

  static from(...disposables) {
    return new Disposable(() => {
      for (const d of disposables) {
        if (d && typeof d.dispose === "function") d.dispose();
      }
    });
  }
}

// ---------------------------------------------------------------------------
// Position, Range, Selection
// ---------------------------------------------------------------------------
class Position {
  constructor(line, character) {
    this.line = line;
    this.character = character;
  }
}

class Range {
  constructor(startLineOrPos, startCharOrEndPos, endLine, endChar) {
    if (startLineOrPos instanceof Position) {
      this.start = startLineOrPos;
      this.end = startCharOrEndPos;
    } else {
      this.start = new Position(startLineOrPos, startCharOrEndPos);
      this.end = new Position(endLine, endChar);
    }
  }
}

class Selection extends Range {
  constructor(anchorLineOrPos, anchorCharOrActivePos, activeLine, activeChar) {
    if (anchorLineOrPos instanceof Position) {
      super(anchorLineOrPos, anchorCharOrActivePos);
      this.anchor = anchorLineOrPos;
      this.active = anchorCharOrActivePos;
    } else {
      const anchor = new Position(anchorLineOrPos, anchorCharOrActivePos);
      const active = new Position(activeLine, activeChar);
      super(anchor, active);
      this.anchor = anchor;
      this.active = active;
    }
  }
}

// ---------------------------------------------------------------------------
// RelativePattern
// ---------------------------------------------------------------------------
class RelativePattern {
  constructor(base, pattern) {
    if (typeof base === "string") {
      this.baseUri = Uri.file(base);
      this.base = base;
    } else if (base instanceof Uri) {
      this.baseUri = base;
      this.base = base.fsPath;
    } else {
      // WorkspaceFolder-like with .uri
      this.baseUri = base.uri;
      this.base = base.uri.fsPath;
    }
    this.pattern = pattern;
  }
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------
const ViewColumn = { Active: -1, Beside: -2, One: 1, Two: 2, Three: 3, Four: 4, Five: 5, Six: 6, Seven: 7, Eight: 8, Nine: 9 };
const StatusBarAlignment = { Left: 1, Right: 2 };
const ExtensionMode = { Production: 1, Development: 2, Test: 3 };
const ConfigurationTarget = { Global: 1, Workspace: 2, WorkspaceFolder: 3 };
const ProgressLocation = { SourceControl: 1, Window: 10, Notification: 15 };
const UIKind = { Desktop: 1, Web: 2 };
const TextEditorRevealType = { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 };
const TextDocumentChangeReason = { Undo: 1, Redo: 2 };
const DiagnosticSeverity = { Error: 0, Warning: 1, Information: 2, Hint: 3 };
const FileType = { Unknown: 0, File: 1, Directory: 2, SymbolicLink: 64 };
// Invoke = 1, Automatic = 2. CC 2.1.331 compares this inside the quick-fix provider.
const CodeActionTriggerKind = { Invoke: 1, Automatic: 2 };
const FileChangeType = { Changed: 1, Created: 2, Deleted: 3 };
const NotebookCellKind = { Markup: 1, Code: 2 };
const NotebookEditorRevealType = { Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 };

// ---------------------------------------------------------------------------
// Tab types (for instanceof checks)
// ---------------------------------------------------------------------------
class TabInputText {
  constructor(uri) {
    this.uri = uri;
  }
}

class TabInputTextDiff {
  constructor(original, modified) {
    this.original = original;
    this.modified = modified;
  }
}

class TabInputWebview {
  constructor(viewType) {
    this.viewType = viewType;
  }
}

// ---------------------------------------------------------------------------
// FileSystemError
// ---------------------------------------------------------------------------
// `code` is the string VS Code puts on `err.code` ("FileNotFound", …).
// CC 2.1.331's .gitignore reader switches on that, not on Node's errno.
class FileSystemError extends Error {
  constructor(message, code = "Unknown") {
    super(message);
    this.name = "FileSystemError";
    this.code = code;
  }

  static FileNotFound(uri) {
    return new FileSystemError(`File not found: ${uri}`, "FileNotFound");
  }

  static FileExists(uri) {
    return new FileSystemError(`File exists: ${uri}`, "FileExists");
  }

  static FileNotADirectory(uri) {
    return new FileSystemError(`Not a directory: ${uri}`, "FileNotADirectory");
  }

  static FileIsADirectory(uri) {
    return new FileSystemError(`Is a directory: ${uri}`, "FileIsADirectory");
  }

  static NoPermissions(uri) {
    return new FileSystemError(`No permissions: ${uri}`, "NoPermissions");
  }

  static Unavailable(uri) {
    return new FileSystemError(`Unavailable: ${uri}`, "Unavailable");
  }
}

// ---------------------------------------------------------------------------
// CodeActionKind / CodeAction
// ---------------------------------------------------------------------------
// Hierarchical kind strings, same shape as VS Code's extHostTypes. CC 2.1.331
// evaluates `vscode.CodeActionKind.QuickFix` while registering its quick-fix
// provider, synchronously inside activate (the same function that registers
// insertAtMention). The value is only stored on the returned action; nothing
// here calls contains(). A missing export throws, activate rejects, and the
// shim exits 1 — no session opens.
class CodeActionKind {
  static sep = ".";

  constructor(value) {
    this.value = value;
  }

  append(parts) {
    return new CodeActionKind(this.value ? this.value + CodeActionKind.sep + parts : parts);
  }

  contains(other) {
    return this.value === other.value || other.value.startsWith(this.value + CodeActionKind.sep);
  }

  intersects(other) {
    return this.contains(other) || other.contains(this);
  }
}

CodeActionKind.Empty = new CodeActionKind("");
CodeActionKind.QuickFix = CodeActionKind.Empty.append("quickfix");
CodeActionKind.Refactor = CodeActionKind.Empty.append("refactor");
CodeActionKind.RefactorExtract = CodeActionKind.Refactor.append("extract");
CodeActionKind.RefactorInline = CodeActionKind.Refactor.append("inline");
CodeActionKind.RefactorMove = CodeActionKind.Refactor.append("move");
CodeActionKind.RefactorRewrite = CodeActionKind.Refactor.append("rewrite");
CodeActionKind.Source = CodeActionKind.Empty.append("source");
CodeActionKind.SourceOrganizeImports = CodeActionKind.Source.append("organizeImports");
CodeActionKind.SourceFixAll = CodeActionKind.Source.append("fixAll");
CodeActionKind.Notebook = CodeActionKind.Empty.append("notebook");

class CodeAction {
  constructor(title, kind) {
    this.title = title;
    this.kind = kind;
  }
}

// ---------------------------------------------------------------------------
// Notebook stubs
// ---------------------------------------------------------------------------
class NotebookCellData {
  constructor(kind, value, languageId) {
    this.kind = kind;
    this.value = value;
    this.languageId = languageId;
  }
}

class NotebookCellOutputItem {
  static error(err) {
    return new NotebookCellOutputItem(err);
  }

  constructor(data) {
    this.data = data;
  }
}

class NotebookEdit {
  static insertCells(index, cells) {
    return new NotebookEdit(index, cells);
  }

  constructor(index, cells) {
    this.index = index;
    this.cells = cells;
  }
}

class NotebookRange {
  constructor(start, end) {
    this.start = start;
    this.end = end;
  }
}

// ---------------------------------------------------------------------------
// WorkspaceEdit
// ---------------------------------------------------------------------------
class WorkspaceEdit {
  constructor() {
    this._edits = new Map();
  }

  set(uri, edits) {
    this._edits.set(uri, edits);
  }
}

// ---------------------------------------------------------------------------
// CancellationTokenNone
// ---------------------------------------------------------------------------
const CancellationTokenNone = {
  isCancellationRequested: false,
  onCancellationRequested: () => new Disposable(() => {}),
};

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------
module.exports = {
  Uri,
  EventEmitter,
  Disposable,
  Position,
  Range,
  Selection,
  RelativePattern,
  ViewColumn,
  StatusBarAlignment,
  ExtensionMode,
  ConfigurationTarget,
  ProgressLocation,
  UIKind,
  TextEditorRevealType,
  TextDocumentChangeReason,
  DiagnosticSeverity,
  CodeActionTriggerKind,
  CodeActionKind,
  CodeAction,
  FileType,
  FileChangeType,
  NotebookCellKind,
  NotebookEditorRevealType,
  TabInputText,
  TabInputTextDiff,
  TabInputWebview,
  FileSystemError,
  NotebookCellData,
  NotebookCellOutputItem,
  NotebookEdit,
  NotebookRange,
  WorkspaceEdit,
  CancellationTokenNone,
};
