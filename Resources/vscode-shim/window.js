"use strict";

const { writeStdout } = require("./protocol.js");
const {
  EventEmitter,
  Disposable,
  CancellationTokenNone,
} = require("./types.js");
const { createNotificationHandler } = require("./notifications.js");

// ---------------------------------------------------------------------------
// createWindow — full vscode.window shim
// ---------------------------------------------------------------------------

function createWindow() {
  const notifications = createNotificationHandler();
  const providers = new Map(); // viewType → provider
  let activeView = null;

  // -------------------------------------------------------------------------
  // Webview bridge
  // -------------------------------------------------------------------------

  function createWebviewObject(_extensionUri) {
    const onDidReceiveMessageEmitter = new EventEmitter();

    const webview = {
      postMessage(message) {
        writeStdout({ type: "webview_message", message });
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

      const base = {
        name,
        append(value) {
          process.stderr.write(value);
        },
        appendLine(value) {
          process.stderr.write(value + "\n");
        },
        clear() {},
        show() {},
        hide() {},
        dispose() {},
        replace(value) {
          process.stderr.write(value);
        },
      };

      if (isLog) {
        // LogOutputChannel — adds info/warn/error/debug/trace methods
        base.logLevel = 2; // Info
        base.onDidChangeLogLevel = noopEvent;
        base.trace = (...args) => {
          process.stderr.write(`[${name}] TRACE: ${args.map(String).join(" ")}\n`);
        };
        base.debug = (...args) => {
          process.stderr.write(`[${name}] DEBUG: ${args.map(String).join(" ")}\n`);
        };
        base.info = (...args) => {
          process.stderr.write(`[${name}] INFO: ${args.map(String).join(" ")}\n`);
        };
        base.warn = (...args) => {
          process.stderr.write(`[${name}] WARN: ${args.map(String).join(" ")}\n`);
        };
        base.error = (...args) => {
          process.stderr.write(`[${name}] ERROR: ${args.map(String).join(" ")}\n`);
        };
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

module.exports = { createWindow };
