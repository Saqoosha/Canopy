"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { Uri, Disposable } = require("./types.js");

// ---------------------------------------------------------------------------
// Memento (globalState implementation)
// ---------------------------------------------------------------------------
class Memento {
  constructor(filePath) {
    this._filePath = filePath;
    this._data = {};
    try {
      const raw = fs.readFileSync(filePath, "utf-8");
      this._data = JSON.parse(raw);
    } catch {
      // File doesn't exist or invalid JSON — start empty
    }
  }

  get(key, defaultValue) {
    if (Object.prototype.hasOwnProperty.call(this._data, key)) {
      return this._data[key];
    }
    return defaultValue;
  }

  update(key, value) {
    if (value === undefined) {
      delete this._data[key];
    } else {
      // Force-disable CC auth gate — Hangar uses keychain auth, not secrets API
      if (key === "experimentGates" && value && typeof value === "object") {
        value = { ...value, tengu_vscode_cc_auth: false };
      }
      this._data[key] = value;
    }
    const dir = path.dirname(this._filePath);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(this._filePath, JSON.stringify(this._data, null, 2), "utf-8");
    try { fs.chmodSync(this._filePath, 0o600); } catch { /* best effort */ }
  }

  keys() {
    return Object.keys(this._data);
  }
}

// ---------------------------------------------------------------------------
// createExtensionContext
// ---------------------------------------------------------------------------
function createExtensionContext({ extensionPath, storagePath }) {
  const extensionUri = Uri.file(extensionPath);
  const globalStateFile = path.join(storagePath, "globalState.json");
  const globalState = new Memento(globalStateFile);

  let packageJSON = {};
  try {
    const raw = fs.readFileSync(path.join(extensionPath, "package.json"), "utf-8");
    packageJSON = JSON.parse(raw);
  } catch {
    // Extension path may not have package.json
  }

  const noopDisposable = () => new Disposable(() => {});

  // File-backed secrets store (production would use macOS keychain)
  const secretsFile = path.join(storagePath, "secrets.json");
  let secretsData = {};
  try {
    secretsData = JSON.parse(fs.readFileSync(secretsFile, "utf-8"));
  } catch { /* start empty */ }

  function saveSecrets() {
    fs.mkdirSync(path.dirname(secretsFile), { recursive: true });
    fs.writeFileSync(secretsFile, JSON.stringify(secretsData, null, 2), "utf-8");
    try { fs.chmodSync(secretsFile, 0o600); } catch { /* best effort */ }
  }

  const secretsOnDidChange = new (require("./types.js").EventEmitter)();

  return {
    subscriptions: [],
    extensionPath,
    extensionUri,
    globalState,
    asAbsolutePath(relativePath) {
      return path.join(extensionPath, relativePath);
    },
    logUri: Uri.file(path.join(storagePath, "logs")),
    logPath: path.join(storagePath, "logs"),
    extension: {
      id: "anthropic.claude-code",
      extensionUri,
      extensionPath,
      packageJSON,
    },
    storageUri: Uri.file(storagePath),
    globalStorageUri: Uri.file(storagePath),
    storagePath,
    globalStoragePath: storagePath,
    extensionMode: 1, // Production
    environmentVariableCollection: {
      persistent: false,
      description: "",
      replace() {},
      append() {},
      prepend() {},
      get() { return undefined; },
      forEach() {},
      delete() {},
      clear() {},
      [Symbol.iterator]() { return [][Symbol.iterator](); },
    },
    secrets: {
      async get(key) { return secretsData[key]; },
      async store(key, value) {
        secretsData[key] = value;
        saveSecrets();
        secretsOnDidChange.fire({ key });
      },
      async delete(key) {
        delete secretsData[key];
        saveSecrets();
        secretsOnDidChange.fire({ key });
      },
      onDidChange: secretsOnDidChange.event,
    },
  };
}

module.exports = { createExtensionContext, Memento };
