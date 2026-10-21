"use strict";

const { writeStdout } = require("./protocol.js");
const {
  EventEmitter,
  Disposable,
  CancellationTokenNone,
} = require("./types.js");
const { createNotificationHandler } = require("./notifications.js");
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
// here is a dead click — v2.1.305 leads the initialize_timeout error with
// that link. The host already turns show_document into ContentViewer, and a
// daemon session forwards the same message to the Mac client.
//
// stderr still receives every write, unchanged, and os_log reads that. This
// buffer is a second copy of the tail, not a new log. A few thousand lines
// covers a failed launch; a long session must not keep everything, because
// the document is one NDJSON line and MirrorUIFrame.maxInlineContentBytes is
// 2 MiB (JSON escaping can grow a line 6× toward the 16 MiB line limit).
const OUTPUT_CHANNEL_MAX_LINES = 4000;
const OUTPUT_CHANNEL_MAX_BYTES = 1_500_000;
const OUTPUT_CHANNEL_TRUNCATION_NOTE =
  "(earlier output dropped; showing the most recent lines)";

// Longest suffix of `text` whose UTF-8 length is at most `maxBytes`.
// Buffer.byteLength counts a lone surrogate as U+FFFD (3 bytes), so the
// shortest suffix under the cap can begin on the trailing half of an emoji.
// Drop that half: the document is shown as text, and a split pair would
// render as a replacement character on the first line of the viewer.
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
  // Complete lines, without their terminating newline. `bytes` counts those
  // newlines too. The incomplete tail lives in `partial` and is not in `bytes`.
  const lines = [];
  let partial = "";
  let bytes = 0;
  let dropped = false;

  function pushLine(line) {
    lines.push(line);
    bytes += Buffer.byteLength(line) + 1;
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
      if (!dropped || body.length === 0) return body;
      return `${OUTPUT_CHANNEL_TRUNCATION_NOTE}\n${body}`;
    },
  };
}

function createWindow() {
  const notifications = createNotificationHandler();
  const providers = new Map(); // viewType → provider
  let activeView = null;

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

    showTextDocument(doc, _options) {
      writeStdout({
        type: "show_document",
        content: typeof doc.getText === "function" ? doc.getText() : "",
        fileName: doc.fileName || (doc.uri && doc.uri.fsPath) || "untitled",
        languageId: doc.languageId || "plaintext",
      });
      return Promise.resolve({});
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

      // Same bytes to stderr and the ring. stderr is what os_log reads;
      // writing only one of them is how the viewer would drift from the log.
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
        // LogOutputChannel. Every level is recorded: logLevel is not
        // consulted, and a startup failure is diagnosed from debug lines.
        base.logLevel = 2; // Info
        base.onDidChangeLogLevel = noopEvent;
        const logAt = (level, args) => {
          emit(`[${name}] ${level}: ${args.map(String).join(" ")}\n`);
        };
        base.trace = (...args) => logAt("TRACE", args);
        base.debug = (...args) => logAt("DEBUG", args);
        base.info = (...args) => logAt("INFO", args);
        base.warn = (...args) => logAt("WARN", args);
        base.error = (...args) => logAt("ERROR", args);
      }

      return base;
    },

    createTerminal(opts) {
      const name =
        typeof opts === "string" ? opts : (opts && opts.name) || "Terminal";
      writeStdout({ type: "open_terminal", name });
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
