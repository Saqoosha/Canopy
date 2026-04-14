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
        process.stderr.write(`[shim:EventEmitter] listener threw: ${err?.stack || err}\n`);
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
class FileSystemError extends Error {
  constructor(message) {
    super(message);
    this.name = "FileSystemError";
  }

  static FileNotFound(uri) {
    return new FileSystemError(`File not found: ${uri}`);
  }

  static FileExists(uri) {
    return new FileSystemError(`File exists: ${uri}`);
  }

  static FileNotADirectory(uri) {
    return new FileSystemError(`Not a directory: ${uri}`);
  }

  static FileIsADirectory(uri) {
    return new FileSystemError(`Is a directory: ${uri}`);
  }

  static NoPermissions(uri) {
    return new FileSystemError(`No permissions: ${uri}`);
  }

  static Unavailable(uri) {
    return new FileSystemError(`Unavailable: ${uri}`);
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
  ConfigurationTarget,
  ProgressLocation,
  UIKind,
  TextEditorRevealType,
  TextDocumentChangeReason,
  DiagnosticSeverity,
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
