#!/usr/bin/env node
"use strict";

// CRITICAL: Redirect console BEFORE anything else
console.log = (...args) => process.stderr.write("[ext:log] " + args.map(String).join(" ") + "\n");
console.warn = (...args) => process.stderr.write("[ext:warn] " + args.map(String).join(" ") + "\n");
console.error = (...args) => process.stderr.write("[ext:error] " + args.map(String).join(" ") + "\n");

const Module = require("node:module");
const path = require("node:path");
const fs = require("node:fs");

// SSH remote: the workspace folder lives on the remote machine and is absent
// locally. CC extension 2.1.112 calls fs.realpathSync(workspaceFolder) without
// try/catch during webview view setup, crashing the shim with ENOENT. Patch
// the sync forms to return the input path unresolved on ENOENT so the
// extension can proceed; other fs operations against the remote path are
// already expected to fail gracefully (documented SSH limitations).
if (process.env.CANOPY_SSH_HOST) {
  process.stderr.write(
    `[vscode-shim] SSH remote mode (host=${process.env.CANOPY_SSH_HOST}); installing fs/spawn patches\n`,
  );

  const origRealpathSync = fs.realpathSync;
  function patchedRealpathSync(p, options) {
    try {
      return origRealpathSync.call(fs, p, options);
    } catch (err) {
      if (err && err.code === "ENOENT") return typeof p === "string" ? p : String(p);
      throw err;
    }
  }
  if (typeof origRealpathSync.native === "function") {
    const origNative = origRealpathSync.native;
    patchedRealpathSync.native = function (p, options) {
      try {
        return origNative.call(fs, p, options);
      } catch (err) {
        if (err && err.code === "ENOENT") return typeof p === "string" ? p : String(p);
        throw err;
      }
    };
  }
  fs.realpathSync = patchedRealpathSync;

  // CC extension 2.1.112 passes the workspace folder as cwd when spawning the
  // CLI wrapper. In SSH mode the folder only exists remotely, so spawn
  // ENOENTs — the extension misreports this as "native binary not found".
  // The wrapper ignores cwd (uses CANOPY_SSH_CWD env var), so redirect cwd
  // to HOME for the wrapper spawn. Other spawns (git, ripgrep, MCP) must NOT
  // be rewritten: they would run in HOME and return wrong results (e.g.
  // @-mention would list HOME files instead of failing cleanly, which is the
  // documented SSH limitation).
  const child_process = require("node:child_process");
  const origSpawn = child_process.spawn;
  const homeDir = process.env.HOME || require("node:os").homedir();
  const wrapperPath = process.env.CANOPY_SSH_WRAPPER_PATH || "";
  function cwdExistsLocally(p) {
    try { return fs.existsSync(p); } catch { return false; }
  }
  function isSshWrapper(command) {
    // Exact-path match against the wrapper Swift bundled and passed via env.
    // Avoids false positives on user-configured custom wrappers that happen
    // to share the basename, and false negatives if the path layout changes.
    return typeof command === "string" && wrapperPath !== "" && command === wrapperPath;
  }
  function rewriteCwd(options) {
    if (!options || typeof options.cwd !== "string") return options;
    if (cwdExistsLocally(options.cwd)) return options;
    return { ...options, cwd: homeDir };
  }
  child_process.spawn = function (command, argsOrOptions, options) {
    if (!isSshWrapper(command)) return origSpawn.apply(this, arguments);
    if (Array.isArray(argsOrOptions)) {
      return origSpawn.call(this, command, argsOrOptions, rewriteCwd(options));
    }
    // spawn(command, options) overload — argsOrOptions is actually options.
    if (argsOrOptions && typeof argsOrOptions === "object") {
      return origSpawn.call(this, command, rewriteCwd(argsOrOptions));
    }
    // spawn(command) — no args/options at all.
    return origSpawn.call(this, command);
  };
}

const { writeStdout, startStdinReader } = require("./protocol.js");
const { createExtensionContext } = require("./context.js");
const { createCommands } = require("./commands.js");
const { createWorkspace } = require("./workspace.js");
const { createWindow } = require("./window.js");
const { createEnv } = require("./env.js");
const { assembleVscodeModule } = require("./stubs.js");

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--extension-path" && argv[i + 1]) {
      args.extensionPath = argv[++i];
    } else if (arg === "--cwd" && argv[i + 1]) {
      args.cwd = argv[++i];
    } else if (arg === "--resume" && argv[i + 1]) {
      args.resume = argv[++i];
    } else if (arg === "--permission-mode" && argv[i + 1]) {
      args.permissionMode = argv[++i];
    } else if (arg === "--settings-path" && argv[i + 1]) {
      args.settingsPath = argv[++i];
    }
  }
  return args;
}

// ---------------------------------------------------------------------------
// Glob resolution for extension path containing *
// ---------------------------------------------------------------------------
function resolveExtensionPath(extPath) {
  if (!extPath.includes("*")) return extPath;
  const dir = path.dirname(extPath);
  const pattern = path.basename(extPath);
  if (!fs.existsSync(dir)) return extPath;
  const entries = fs.readdirSync(dir);
  // Convert glob pattern to regex (simple: * → .*)
  const re = new RegExp("^" + pattern.replace(/\*/g, ".*") + "$");
  const matches = entries.filter((e) => re.test(e)).sort();
  if (matches.length === 0) return extPath;
  // Use the latest (last sorted) entry
  return path.join(dir, matches[matches.length - 1]);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const args = parseArgs(process.argv);

  // Validate required args
  if (!args.extensionPath) {
    writeStdout({ type: "error", message: "Missing required arg: --extension-path" });
    process.exit(1);
  }
  if (!args.cwd) {
    writeStdout({ type: "error", message: "Missing required arg: --cwd" });
    process.exit(1);
  }

  // Resolve extension path (supports glob)
  const extensionPath = resolveExtensionPath(args.extensionPath);

  // extension.js can be at root (newer CC builds) or in dist/ (older)
  let extensionJsPath = path.join(extensionPath, "extension.js");
  if (!fs.existsSync(extensionJsPath)) {
    extensionJsPath = path.join(extensionPath, "dist", "extension.js");
  }

  if (!fs.existsSync(extensionJsPath)) {
    writeStdout({ type: "error", message: `extension.js not found in ${extensionPath} (checked root and dist/)` });
    process.exit(1);
  }

  // Read extension's package.json
  let extensionPackageJson = {};
  try {
    const raw = fs.readFileSync(path.join(extensionPath, "package.json"), "utf-8");
    extensionPackageJson = JSON.parse(raw);
  } catch {
    // Non-fatal — extension may work without it
  }

  // Storage path
  const storagePath = path.join(
    process.env.HOME || process.env.USERPROFILE || "/tmp",
    "Library",
    "Application Support",
    "Canopy",
  );

  // Create all modules
  const commands = createCommands();
  const workspace = createWorkspace({
    cwd: args.cwd,
    settingsPath: path.join(args.cwd, ".vscode", "settings.json"),
    extensionPackageJson,
    canopySettingsPath: args.settingsPath,
  });
  const window = createWindow();
  const env = createEnv({
    machineIdPath: path.join(storagePath, "machineId"),
    remoteName: undefined,
  });

  // Assemble vscode shim
  const vscodeModule = assembleVscodeModule({ window, workspace, commands, env });

  // Hook Module._resolveFilename to intercept require("vscode")
  const origResolveFilename = Module._resolveFilename;
  Module._resolveFilename = function (request, parent, isMain, options) {
    if (request === "vscode") return "vscode";
    return origResolveFilename.call(this, request, parent, isMain, options);
  };
  require.cache.vscode = { id: "vscode", filename: "vscode", loaded: true, exports: vscodeModule };

  // Create ExtensionContext
  const context = createExtensionContext({ extensionPath, storagePath });

  // Start stdin reader. When stdin closes (Canopy exits/crashes), exit gracefully.
  let webviewReady = false;
  const stdinRl = startStdinReader((msg) => {
    if (msg.type === "webview_message") {
      window._handleWebviewMessage(msg.message);
    } else if (msg.type === "webview_ready") {
      webviewReady = true;
    } else if (msg.type === "notification_response") {
      window._handleNotificationResponse(msg.requestId, msg.buttonValue);
    }
  });
  stdinRl.on("close", () => {
    process.stderr.write("[vscode-shim] stdin closed, exiting\n");
    process.exit(0);
  });

  // Process cleanup: kill all children on exit.
  // Cannot use process.kill(-pid) — we share the parent's process group,
  // so that would kill Canopy itself. Instead, find and kill children individually.
  function killChildren() {
    try {
      const { execSync } = require("node:child_process");
      const output = execSync(`/usr/bin/pgrep -P ${process.pid}`, { encoding: "utf-8", timeout: 2000 });
      for (const line of output.trim().split("\n")) {
        const childPid = parseInt(line, 10);
        if (childPid > 0) {
          try { process.kill(childPid, "SIGTERM"); } catch { /* already dead */ }
        }
      }
    } catch {
      // pgrep exits 1 when no children found — expected
    }
  }
  process.on("exit", killChildren);
  process.on("SIGTERM", () => process.exit(0));
  process.on("SIGINT", () => process.exit(0));

  // Load and activate extension
  const savedCwd = process.cwd();
  process.chdir(extensionPath);
  try {
    const ext = require(extensionJsPath);
    await ext.activate(context);
  } catch (err) {
    process.stderr.write(`[vscode-shim] Activation error: ${err.stack}\n`);
    writeStdout({ type: "error", message: `Extension activation failed: ${err.message}` });
    process.exit(1);
  } finally {
    process.chdir(savedCwd);
  }

  // Activate the first webview provider
  window._activateFirstProvider();

  // Signal readiness
  writeStdout({ type: "ready" });
}

main().catch((err) => {
  writeStdout({ type: "error", message: `Fatal: ${err.message}` });
  process.exit(1);
});
