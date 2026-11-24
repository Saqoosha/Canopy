"use strict";

const types = require("./types.js");
const { writeStdout } = require("./protocol.js");
const { Disposable } = types;

const warnedStubs = new Set();
function warnOnce(apiName) {
  if (warnedStubs.has(apiName)) return;
  warnedStubs.add(apiName);
  process.stderr.write(`[vscode-shim] WARN: Stub called: ${apiName}\n`);
  writeStdout({ type: "log", level: "warn", msg: `Stub called: ${apiName}` });
}

// VS Code's languages.match score: 10 for a language hit, 5 for "*", 0 for
// no match. CC 2.1.331 calls this only after
// executeCommand("vscode.resolveNotebookContentProviders"), which resolves
// undefined here, so the caller returns before match(). A pattern-only
// selector (notebook filename associations) scores 0: Canopy has no notebooks.
function matchDocumentSelector(selector, document) {
  if (Array.isArray(selector)) {
    let best = 0;
    for (const item of selector) {
      const score = matchDocumentSelector(item, document);
      if (score > best) best = score;
      if (best === 10) break;
    }
    return best;
  }
  const languageId = document && document.languageId;
  if (typeof selector === "string") {
    if (selector === "*") return 5;
    return selector === languageId ? 10 : 0;
  }
  if (selector && typeof selector === "object" && typeof selector.language === "string") {
    if (selector.language === "*") return 5;
    return selector.language === languageId ? 10 : 0;
  }
  return 0;
}

function assembleVscodeModule({ window, workspace, commands, env }) {
  const knownApis = {
    ...types, // All types, enums, classes
    window,
    workspace,
    commands,
    env,
    // registerCodeActionsProvider is called during CC 2.1.331 activate, in
    // the same push() as the quick-fix command. The provider is never
    // invoked: Canopy has no diagnostics surface. It still has to exist and
    // return a Disposable, or activate throws and the shim exits 1.
    languages: {
      getDiagnostics: () => [],
      onDidChangeDiagnostics: () => new Disposable(() => {}),
      registerCodeActionsProvider() {
        return new Disposable(() => {});
      },
      match: matchDocumentSelector,
    },
    extensions: {
      getExtension: () => undefined,
      all: [],
    },
    version: "1.100.0",
  };

  // Proxy detects access to unknown APIs
  return new Proxy(knownApis, {
    get(target, prop) {
      if (prop in target) return target[prop];
      if (typeof prop === "symbol") return undefined;
      const msg = `Unknown vscode API accessed: vscode.${String(prop)}`;
      process.stderr.write(`[vscode-shim] WARN: ${msg}\n`);
      writeStdout({ type: "log", level: "warn", msg });
      return undefined;
    },
  });
}

module.exports = { assembleVscodeModule, matchDocumentSelector, warnOnce };
