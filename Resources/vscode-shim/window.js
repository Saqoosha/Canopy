"use strict";

const { writeStdout } = require("./protocol.js");
const {
  EventEmitter,
  Disposable,
  CancellationTokenNone,
  Uri,
} = require("./types.js");
const { readFileTextDocument } = require("./workspace.js");
const { createNotificationHandler } = require("./notifications.js");
const { activationLogText } = require("./activation-error.js");
const { createEmphasisRepairer } = require("./cjk-emphasis-stream.js");

// ---------------------------------------------------------------------------
// createWindow — full vscode.window shim
// ---------------------------------------------------------------------------

// One repairer per shim process, not per webview. `createWebviewPanel` makes a
// second webview, and a second repairer would keep its own counters and write
// `session …` totals for a different object into the same log stream, with
// nothing in the line saying which. "Session" in the tally now means the
// process, which is what the word was already doing in the log.
//
// The line below says only that this build wired the repair up. It cannot say
// the repair is working — the first version of this feature printed it while
// every frame passed through untouched. The per-turn tally is what distinguishes
// those two.
let emphasisRepairer;
let announcedEmphasisRepair; // the enablement last announced, not a boolean latch
function getEmphasisRepairer() {
  const enabled = process.env.CANOPY_DISABLE_CJK_EMPHASIS_REPAIR !== "1";
  // Announce the value OBSERVED, not the first one. A plain latch let the log
  // say `armed` while a later call returned null and forwarded frames untouched
  // — an announcement asserting the opposite of the behaviour, which is the
  // "reports itself healthy" mode this line exists to rule out.
  if (announcedEmphasisRepair !== enabled) {
    announcedEmphasisRepair = enabled;
    process.stderr.write(
      enabled
        ? "[cjk-emphasis] armed (CANOPY_DISABLE_CJK_EMPHASIS_REPAIR=1 turns it off)\n"
        : "[cjk-emphasis] disabled by CANOPY_DISABLE_CJK_EMPHASIS_REPAIR\n",
    );
  }
  if (!enabled) return null;
  if (!emphasisRepairer) emphasisRepairer = createEmphasisRepairer();
  return emphasisRepairer;
}

// Recent output kept so OutputChannel.show() can open it. The Claude Code
// extension's "View output logs" link sends open_output_panel, and the
// extension handles that by calling show() on its LogOutputChannel. A no-op
// here is a dead click.
//
// stderr still receives every write, unchanged, and os_log reads that. This
// buffer is a second copy of the tail, not a new log. The byte cap stays under
// MirrorUIFrame.maxInlineContentBytes, because inlineContent keeps the head
// and would drop the newest lines.
const OUTPUT_CHANNEL_MAX_LINES = 4000;
const OUTPUT_CHANNEL_MAX_BYTES = 1_500_000;
const OUTPUT_CHANNEL_TRUNCATION_NOTE =
  "(earlier output dropped; showing the most recent lines)";

// Longest suffix of `text` whose UTF-8 length is at most `maxBytes`.
// Buffer.byteLength counts a lone surrogate as U+FFFD (3 bytes), so the
// shortest suffix under the cap can begin on the trailing half of an emoji.
// Drop that half: JSON.stringify writes it as \udcXX, which JSONSerialization
// rejects, so the whole show_document line would be dropped.
function tailUtf8(text, maxBytes) {
  if (Buffer.byteLength(text) <= maxBytes) return text;
  let lo = 0;
  let hi = text.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (Buffer.byteLength(text.slice(mid)) > maxBytes) lo = mid + 1;
    else hi = mid;
  }
  if (lo < text.length) {
    const unit = text.charCodeAt(lo);
    if (unit >= 0xDC00 && unit <= 0xDFFF) lo += 1;
  }
  return text.slice(lo);
}

function createOutputRing(maxLines, maxBytes) {
  // Complete lines, without their terminating newline; one longer than the cap
  // keeps only its tail. `bytes` counts those newlines too. The incomplete
  // tail lives in `partial` and is not in `bytes`.
  const lines = [];
  let partial = "";
  let bytes = 0;
  let dropped = false;

  function pushLine(line) {
    let size = Buffer.byteLength(line);
    if (size > maxBytes - 1) {
      line = tailUtf8(line, maxBytes - 1);
      size = Buffer.byteLength(line);
      dropped = true;
    }
    lines.push(line);
    bytes += size + 1;
  }

  function trim() {
    let drop = 0;
    let remaining = bytes;
    if (lines.length > maxLines) {
      drop = lines.length - maxLines;
      for (let i = 0; i < drop; i++) remaining -= Buffer.byteLength(lines[i]) + 1;
    }
    const partialBytes = Buffer.byteLength(partial);
    while (drop < lines.length && remaining + partialBytes > maxBytes) {
      remaining -= Buffer.byteLength(lines[drop]) + 1;
      drop++;
    }
    if (drop > 0) {
      lines.splice(0, drop);
      bytes = remaining;
      dropped = true;
    }
    if (partialBytes > maxBytes) {
      partial = tailUtf8(partial, maxBytes);
      dropped = true;
    }
  }

  return {
    append(value) {
      const text = String(value);
      if (text.length === 0) return;
      const parts = text.split("\n");
      partial += parts[0];
      for (let i = 1; i < parts.length; i++) {
        pushLine(partial);
        partial = parts[i];
      }
      trim();
    },
    replace(value) {
      lines.length = 0;
      partial = "";
      bytes = 0;
      dropped = false;
      this.append(value);
    },
    clear() {
      lines.length = 0;
      partial = "";
      bytes = 0;
      dropped = false;
    },
    text() {
      let body;
      if (lines.length === 0) body = partial;
      else if (partial.length === 0) body = lines.join("\n") + "\n";
      else body = `${lines.join("\n")}\n${partial}`;
      if (!dropped) return body;
      return `${OUTPUT_CHANNEL_TRUNCATION_NOTE}\n${body}`;
    },
  };
}

// Claude Code 2.1.330's bypass-permissions dialog calls
// `createTerminal({ shellPath, shellArgs, cwd, env, hideFromUser: true }).show()`
// from `openAutoModeSetup`. `shellPath` is the claude binary (or node, when the
// extension launches the CLI that way) and `shellArgs` ends in `/auto-mode-setup`.
//
// The other `createTerminal` callers pass no `shellPath`. Their command
// arrives via `sendText` (the shim's terminal has no shell integration), which
// is a stub, so those calls must keep writing a name-only `open_terminal`. The host
// opens an idle `cd` into the session directory and runs nothing else.
//
// A `shellPath` terminal is one already-quoted line in `shellCommand`.
// `ShimProcess.terminalShellLine` runs that line in Terminal.app. Quoting
// lives here so a value cannot break out of the line, and so the suite can
// see the exact command. Line breaks and NULs are refused: the host puts the
// line into an AppleScript string passed as an osascript argument. Backslashes are refused: Terminal runs
// the line in the login shell, and fish reads `\'` inside single quotes.
// `cwd` is required because this process's own cwd is the daemon's, not the
// session's.
const SHELL_ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;

function shellQuote(value) {
  return `'${value.replace(/'/g, "'\\''")}'`;
}

function cannotQuote(value) {
  return /[\0\r\n\\]/.test(value);
}

function refuseTerminal(reason) {
  const err = new Error(`Canopy cannot open this terminal: ${reason}`);
  err.code = "CanopyTerminalUnsupported";
  throw err;
}

function shellCommandForTerminal(opts) {
  // SSH sessions run the CLI on the remote host. A local Terminal.app would
  // `cd` to a path that exists only there. `canOpenAutoModeSetup` is false
  // for those sessions (the binary is behind the process wrapper), so this
  // is the guard for a caller that asks anyway.
  if (process.env.CANOPY_SSH_HOST) {
    refuseTerminal("an SSH remote session has no local terminal for a shellPath command");
  }
  const shellPath = opts.shellPath;
  if (typeof shellPath !== "string" || shellPath.length === 0 || cannotQuote(shellPath)) {
    refuseTerminal("shellPath must be a single-line, backslash-free path");
  }
  const shellArgs = opts.shellArgs === undefined ? [] : opts.shellArgs;
  if (!Array.isArray(shellArgs) || shellArgs.some((arg) => typeof arg !== "string" || cannotQuote(arg))) {
    refuseTerminal("shellArgs must be single-line, backslash-free strings");
  }
  if (typeof opts.cwd !== "string" || opts.cwd.length === 0 || cannotQuote(opts.cwd)) {
    refuseTerminal("cwd must be the session directory, as a single-line, backslash-free path");
  }
  const env = opts.env === undefined ? {} : opts.env;
  if (env === null || typeof env !== "object" || Array.isArray(env)) {
    refuseTerminal("env must be an object of strings");
  }
  const unsets = [];
  const sets = [];
  const forwarded = {};
  for (const key of Object.keys(env).sort()) {
    const value = env[key];
    if (value === undefined) continue;
    if (!SHELL_ENV_NAME.test(key)) {
      refuseTerminal(`env key ${JSON.stringify(key)} is not a shell name`);
    }
    if (value === null) {
      unsets.push(key);
      forwarded[key] = null;
      continue;
    }
    if (typeof value !== "string" || cannotQuote(value)) {
      refuseTerminal(`env ${key} must be a single-line, backslash-free string or null`);
    }
    sets.push(shellQuote(`${key}=${value}`));
    forwarded[key] = value;
  }
  const parts = ["cd", shellQuote(opts.cwd), "&&"];
  if (unsets.length > 0 || sets.length > 0) {
    parts.push("/usr/bin/env");
    for (const key of unsets) parts.push("-u", shellQuote(key));
    parts.push(...sets);
  }
  parts.push(shellQuote(shellPath));
  for (const arg of shellArgs) parts.push(shellQuote(arg));
  return {
    shellPath,
    shellArgs: shellArgs.slice(),
    cwd: opts.cwd,
    env: forwarded,
    shellCommand: parts.join(" "),
  };
}

function createWindow() {
  const notifications = createNotificationHandler();
  const providers = new Map(); // viewType → provider
  let activeView = null;
  let activationLog;

  // -------------------------------------------------------------------------
  // Webview bridge
  // -------------------------------------------------------------------------

  function createWebviewObject(_extensionUri) {
    const onDidReceiveMessageEmitter = new EventEmitter();
    // CommonMark cannot close a `**` span whose closer sits between CJK
    // punctuation and a CJK character, so Japanese replies render their markers
    // literally. Repairing here covers live streaming and history replay at
    // once — both reach the webview through this one call. Set
    // CANOPY_DISABLE_CJK_EMPHASIS_REPAIR=1 to forward frames untouched.
    const repairer = getEmphasisRepairer();

    const webview = {
      postMessage(message) {
        // Since 2.1.331 a `true` here makes the extension start a new conversation's CLI before
        // the page's `init`. A `launch_claude` that resumes, or brings its own channel, discards
        // that CLI and starts another, running SessionStart hooks twice. The page ignores the message.
        if (message?.type === "frame-probe") return Promise.resolve(false);
        if (!repairer) {
          writeStdout({ type: "webview_message", message });
          return Promise.resolve(true);
        }
        // One frame in can become two out: a block's held-back tail is released
        // as a synthetic delta ahead of its content_block_stop.
        for (const out of repairer.repairOutbound(message)) {
          writeStdout({ type: "webview_message", message: out });
        }
        return Promise.resolve(true);
      },
      onDidReceiveMessage: onDidReceiveMessageEmitter.event,
      asWebviewUri(uri) {
        return uri;
      },
      cspSource: "",
      options: { enableScripts: true, localResourceRoots: [] },
      html: "", // setter is ignored
      _onDidReceiveMessageEmitter: onDidReceiveMessageEmitter,
    };

    const view = {
      webview,
      visible: true,
      viewType: "",
      show() {},
      onDidChangeVisibility: new EventEmitter().event,
      onDidDispose: new EventEmitter().event,
    };

    return view;
  }

  // -------------------------------------------------------------------------
  // No-op event helper
  // -------------------------------------------------------------------------

  function noopEvent(_listener) {
    return new Disposable(() => {});
  }

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  const window = {
    // -- Webview providers --------------------------------------------------

    registerWebviewViewProvider(viewType, provider) {
      providers.set(viewType, provider);
      return new Disposable(() => providers.delete(viewType));
    },

    /**
     * Create a secondary webview panel.
     * IMPORTANT: Must not replace `activeView`; sidebar remains the primary
     * message conduit for protocol/control messages.
     */
    createWebviewPanel(viewType, _title, _showOptions, _options) {
      const view = createWebviewObject();
      view.viewType = viewType;
      // Do NOT replace activeView — sidebar must remain the primary message conduit.
      // Panels (e.g. plan preview) are secondary; replacing activeView here breaks
      // the sidebar's onDidReceiveMessage routing (e.g. ExitPlanMode responses).
      return view;
    },

    _activateFirstProvider() {
      const first = providers.values().next().value;
      if (!first) return;
      const view = createWebviewObject();
      activeView = view;
      const context = {};
      first.resolveWebviewView(view, context, CancellationTokenNone);
    },

    _handleWebviewMessage(message) {
      if (activeView) {
        activeView.webview._onDidReceiveMessageEmitter.fire(message);
      }
    },

    _handleNotificationResponse(requestId, buttonValue) {
      notifications.handleResponse(requestId, buttonValue);
    },

    _activationLog() {
      return activationLog;
    },

    _getActiveWebview() {
      return activeView ? activeView.webview : null;
    },

    // -- Notifications ------------------------------------------------------

    showInformationMessage(msg, ...args) {
      return notifications.show("info", msg, ...args);
    },

    showErrorMessage(msg, ...args) {
      return notifications.show("error", msg, ...args);
    },

    showWarningMessage(msg, ...args) {
      return notifications.show("warning", msg, ...args);
    },

    // -- showTextDocument ---------------------------------------------------
    //
    // A `file:` Uri is read from disk (`openFile` passes `Uri.file(path)`); a read failure rejects.

    showTextDocument(doc, _options) {
      let shown = doc;
      if (!(doc && typeof doc.getText === "function") && doc instanceof Uri && doc.scheme === "file") {
        try {
          shown = readFileTextDocument(doc.fsPath);
        } catch (err) {
          return Promise.reject(err);
        }
      }
      const hasText = shown && typeof shown.getText === "function";
      writeStdout({
        type: "show_document",
        content: hasText ? shown.getText() : "",
        fileName: (shown && (shown.fileName || (shown.uri && shown.uri.fsPath))) || "untitled",
        languageId: (shown && shown.languageId) || "plaintext",
      });
      if (!hasText) return Promise.resolve({});
      // `openFile` reads `document` and calls `revealRange` after showing; both must exist.
      return Promise.resolve({
        document: shown,
        revealRange() {},
        selection: null,
      });
    },

    // -- Tier 2 stubs -------------------------------------------------------

    showQuickPick() {
      process.stderr.write("[vscode-shim] showQuickPick not supported\n");
      return Promise.resolve(undefined);
    },

    showInputBox() {
      process.stderr.write("[vscode-shim] showInputBox not supported\n");
      return Promise.resolve(undefined);
    },

    withProgress(_opts, fn) {
      const progress = { report() {} };
      return fn(progress, CancellationTokenNone);
    },

    createStatusBarItem() {
      return { text: "", show() {}, hide() {}, dispose() {} };
    },

    createOutputChannel(name, optionsOrLangId) {
      const isLog =
        typeof optionsOrLangId === "object" && optionsOrLangId !== null && optionsOrLangId.log === true;
      const buffer = createOutputRing(OUTPUT_CHANNEL_MAX_LINES, OUTPUT_CHANNEL_MAX_BYTES);

      // stderr is what os_log reads; the ring is the copy show() opens.
      function emit(value) {
        process.stderr.write(value);
        buffer.append(value);
      }

      const base = {
        name,
        append(value) {
          emit(value);
        },
        appendLine(value) {
          emit(value + "\n");
        },
        clear() {
          buffer.clear();
        },
        // preserveFocus / ViewColumn are ignored: the host opens a document,
        // it does not have an output panel to reveal beside an editor.
        show() {
          writeStdout({
            type: "show_document",
            content: buffer.text(),
            fileName: name,
            languageId: "plaintext",
          });
        },
        hide() {},
        dispose() {},
        replace(value) {
          process.stderr.write(value);
          buffer.replace(value);
        },
      };

      if (isLog) {
        // LogOutputChannel. Every level is recorded; logLevel is not consulted.
        base.logLevel = 2; // Info
        base.onDidChangeLogLevel = noopEvent;
        const logAt = (level, args) => {
          emit(`[${name}] ${level}: ${args.map(String).join(" ")}\n`);
        };
        base.trace = (...args) => logAt("TRACE", args);
        base.debug = (...args) => logAt("DEBUG", args);
        base.info = (...args) => logAt("INFO", args);
        base.warn = (...args) => logAt("WARN", args);
        base.error = (...args) => {
          activationLog = activationLogText(args) ?? activationLog;
          logAt("ERROR", args);
        };
      }

      return base;
    },

    // `hideFromUser` is ignored. The only `shellPath` caller sets it and then
    // calls `show()` immediately, and Canopy has no terminal panel to hide a
    // window in.
    createTerminal(opts) {
      const name =
        typeof opts === "string" ? opts : (opts && opts.name) || "Terminal";
      if (opts && typeof opts === "object" && opts.shellPath !== undefined) {
        const hosted = shellCommandForTerminal(opts);
        const msg = {
          type: "open_terminal",
          name,
          shellPath: hosted.shellPath,
          shellArgs: hosted.shellArgs,
          cwd: hosted.cwd,
          shellCommand: hosted.shellCommand,
        };
        if (opts.env !== undefined) msg.env = hosted.env;
        writeStdout(msg);
      } else {
        writeStdout({ type: "open_terminal", name });
      }
      return {
        name,
        processId: Promise.resolve(undefined),
        sendText() {},
        show() {},
        hide() {},
        dispose() {},
      };
    },

    registerWebviewPanelSerializer() {
      return new Disposable(() => {});
    },

    registerUriHandler() {
      return new Disposable(() => {});
    },

    // -- Read-only properties -----------------------------------------------

    get activeTextEditor() {
      return undefined;
    },

    get visibleTextEditors() {
      return [];
    },

    get terminals() {
      return [];
    },

    get activeTerminal() {
      return undefined;
    },

    get activeNotebookEditor() {
      return undefined;
    },

    get tabGroups() {
      return {
        all: [],
        activeTabGroup: { tabs: [], isActive: true, viewColumn: 1 },
        onDidChangeTabs: noopEvent,
        onDidChangeTabGroups: noopEvent,
        close: async () => false,
      };
    },

    // -- onDidChange* events (all no-op) ------------------------------------

    onDidChangeActiveTextEditor: noopEvent,
    onDidChangeVisibleTextEditors: noopEvent,
    onDidChangeTextEditorSelection: noopEvent,
    onDidChangeTextEditorVisibleRanges: noopEvent,
    onDidChangeActiveTerminal: noopEvent,
    onDidOpenTerminal: noopEvent,
    onDidCloseTerminal: noopEvent,
    onDidChangeWindowState: noopEvent,
    onDidChangeActiveColorTheme: noopEvent,
    onDidChangeTextEditorOptions: noopEvent,
    onDidChangeTextEditorViewColumn: noopEvent,
    onDidChangeActiveNotebookEditor: noopEvent,
    onDidChangeVisibleNotebookEditors: noopEvent,
    onDidChangeNotebookEditorSelection: noopEvent,
  };

  return window;
}

module.exports = {
  createWindow,
  OUTPUT_CHANNEL_MAX_LINES,
  OUTPUT_CHANNEL_MAX_BYTES,
  OUTPUT_CHANNEL_TRUNCATION_NOTE,
};
