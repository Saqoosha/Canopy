"use strict";

const { Disposable } = require("./types.js");

// ---------------------------------------------------------------------------
// Commands — registerCommand / executeCommand / setContext
// ---------------------------------------------------------------------------
function createCommands() {
  const handlers = new Map(); // command id → handler function
  const contextValues = new Map(); // context key → value (for setContext)

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
    // Unknown commands silently ignored (many are VSCode-internal)
  }

  function getContext(key) {
    return contextValues.get(key);
  }

  return { registerCommand, executeCommand, getContext };
}

module.exports = { createCommands };
