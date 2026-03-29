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

function assembleVscodeModule({ window, workspace, commands, env }) {
  const knownApis = {
    ...types, // All types, enums, classes
    window,
    workspace,
    commands,
    env,
    languages: {
      getDiagnostics: () => [],
      onDidChangeDiagnostics: () => new Disposable(() => {}),
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

module.exports = { assembleVscodeModule, warnOnce };
