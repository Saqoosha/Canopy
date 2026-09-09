"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { Uri, Disposable } = require("./types.js");
const { writeStdout } = require("./protocol.js");

// ---------------------------------------------------------------------------
// Memento (backs both globalState and workspaceState)
// ---------------------------------------------------------------------------
class Memento {
  // `forceAuthGate` is set for globalState only; the reason is on the branch it
  // governs, in `update`.
  constructor(filePath, { forceAuthGate = false } = {}) {
    this._filePath = filePath;
    this._forceAuthGate = forceAuthGate;
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
      // Enable CC auth gate — extension uses Secrets API (file-backed in shim) for auth.
      // This allows /login and "Switch Account" to work properly. Gated on
      // `forceAuthGate` because the gate is an install-wide concern: this class
      // now backs workspaceState too, and an unconditional rewrite would fire on
      // a store it was never reasoned about.
      if (this._forceAuthGate && key === "experimentGates" && value && typeof value === "object") {
        value = { ...value, tengu_vscode_cc_auth: true };
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

  // Real VSCode API, declared on `globalState` only. Nothing here syncs, so
  // recording the keys and doing nothing IS the correct implementation — but it
  // has to EXIST, or an extension that calls it dies with `not a function` in
  // the middle of `activate`, which is the shape this whole file's Proxy below
  // is meant to make legible. Kept on the class rather than the globalState
  // instance: one method beats a per-instance graft, and workspaceState having
  // an inert extra is cheaper than the asymmetry.
  setKeysForSync(keys) {
    this._syncKeys = Array.isArray(keys) ? [...keys] : [];
  }
}

// ---------------------------------------------------------------------------
// createExtensionContext
// ---------------------------------------------------------------------------

// A filename component is limited to 255 bytes, and `label` is a basename whose
// length the caller does not control. Uncapped, `label` + the suffix can exceed
// it, and the write lands in `Memento.update`'s unguarded `writeFileSync` — so
// the first write throws. Where that lands decides what it costs, and every
// outcome is bad: inside `activate` it exits the shim 1 and bounces the session
// to the launcher, which is the failure this change exists to stop; from a
// webview message `types.js`'s `EventEmitter.fire` catches it and the state
// silently never persists; from a stdin frame `protocol.js` catches it in the
// same `try` that reports malformed input, so it is swallowed AND misreported as
// `Invalid JSON on stdin` (measured — the shim stays alive and exits 0). Which of
// the three applies depends on when the extension writes, and is NOT established
// here: the only use we have measured is a read.
// Measured: 237 characters of label still fits at exactly 255 bytes and 238 does
// not, so a 250-character workspace basename produces a 268-byte filename and
// throws ENAMETOOLONG. The sanitized label is ASCII-only, so characters and bytes
// agree. 80 rather than the ~237 the limit allows: 98 bytes of 255 in the worst
// case, leaving the name recognisable and the rest as headroom for anything a
// later change wants to prefix.
const MAX_LABEL_LENGTH = 80;

// One file per workspace, because that is what `workspaceState` means: VSCode
// scopes it to the open folder while `globalState` spans the install. Sharing
// one file would let a session id recorded in repo A surface in repo B.
//
// The digest is what disambiguates — 48 bits of SHA-256, so a collision needs on
// the order of 16M workspaces. The sanitized basename is in the name only so the
// directory can be read by a human, and it is a weak reading aid: a non-ASCII
// name collapses to underscores, and the host is deliberately not in it, so the
// remote and local copies of one repo differ only by digest.
//
// The key covers the SSH host as well as the path, because `--cwd` carries a
// remote session's path with no host in it — without that, the same path on two
// machines is one file, precisely the leak this split exists to prevent. It is a
// JSON array rather than a joined string so no host and path can spell the same
// key. It is NOT otherwise normalized: two spellings of one directory get two
// files, symlinks notably, and a host retyped as `mbp` / `hiko@mbp` / `mbp.local`
// gives three. VSCode keys by URI and has the same property.
//
// Concurrent shims on the same cwd clobber each other's keys — each holds the
// whole document in memory and rewrites it wholesale, so the loser's keys are
// deleted rather than merely raced. `globalState` has always carried that, but
// this is likelier rather than merely inherited: two panes on one repo is a
// normal Canopy configuration (and this directory is shared with the Debug
// build, which is a second way to reach it), and `panelSessionIds` is per-pane.
// A losing pane forgets which sessions its panel held. Accepted, not pending: a
// merge-on-write would fix it and is a change of its own.
function workspaceStateFile(storagePath, workspacePath, remoteHost) {
  const key = JSON.stringify([remoteHost || null, workspacePath]);
  const digest = crypto.createHash("sha256").update(key).digest("hex").slice(0, 12);
  const label = path
    .basename(workspacePath)
    .replace(/[^A-Za-z0-9._-]/g, "_")
    .slice(0, MAX_LABEL_LENGTH) || "workspace";
  return path.join(storagePath, "workspaceState", `${label}-${digest}.json`);
}

function createExtensionContext({ extensionPath, storagePath, workspacePath, remoteHost }) {
  // index.js refuses to start without --cwd, so an absent value here is a wiring
  // mistake, and throwing beats writing every workspace into one shared file.
  // Not loud to the USER, though: this exits the shim 1 and Canopy closes the
  // pane with nothing on screen. It is loud in the log and in the tests, which
  // is where a wiring mistake is actually caught.
  if (typeof workspacePath !== "string" || workspacePath.length === 0) {
    throw new TypeError("createExtensionContext: workspacePath is required");
  }
  const extensionUri = Uri.file(extensionPath);
  const globalStateFile = path.join(storagePath, "globalState.json");
  const globalState = new Memento(globalStateFile, { forceAuthGate: true });
  const workspaceState = new Memento(workspaceStateFile(storagePath, workspacePath, remoteHost));

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

  const context = {
    subscriptions: [],
    extensionPath,
    extensionUri,
    globalState,
    workspaceState,
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

  // `ExtensionContext` is a hand-written subset, so an extension update can
  // reach for a member that was never implemented. That is not hypothetical:
  // 2.1.266's `getPanelSessionIds()` read `workspaceState`, got `undefined`,
  // and `undefined.get` threw during `activate` — the shim exited 1 and every
  // session bounced back to the launcher.
  //
  // The Proxy does NOT prevent that; the read still yields `undefined` and the
  // caller still throws. What it buys is the member's NAME at the moment of
  // access. The thrown message names the property read on `undefined`
  // (`reading 'get'`), never `workspaceState`, and the extension's file:line
  // arrives on a separate record — so recovering the member meant reading the
  // minified `extension.js` at that column. One `Unknown ExtensionContext
  // member:` line replaces that whole detour.
  //
  // Same shape as `stubs.js`'s Proxy over the `vscode` namespace, including its
  // symbol carve-out: `util.inspect`, `JSON.stringify` and friends probe well
  // known symbols on any object handed to them, and warning on those would bury
  // the real signal.
  return new Proxy(context, {
    get(target, prop) {
      if (prop in target) return target[prop];
      if (typeof prop === "symbol") return undefined;
      // `then` is probed by the language itself whenever an object reaches a
      // promise position — awaiting one, or resolving a promise with it. A
      // warning there would report the runtime's own bookkeeping as an
      // extension bug.
      if (prop === "then") return undefined;
      const msg = `Unknown ExtensionContext member: ${String(prop)}`;
      process.stderr.write(`[vscode-shim] WARN: ${msg}\n`);
      writeStdout({ type: "log", level: "warn", msg });
      return undefined;
    },
  });
}

module.exports = { createExtensionContext, Memento, workspaceStateFile, MAX_LABEL_LENGTH };
