"use strict";

const util = require("node:util");

// A damaged Claude login must read as "logged out", not crash the shim.
//
// Measured on studio 2026-09-24: the Keychain blob had lost `scopes`, and
// extension 2.1.280/2.1.281 getAuthStatus does `scopes.includes(...)` unguarded,
// so every session died before its webview could offer /login. Dropping the
// unusable `claudeAiOauth` from what the extension reads normally lands it on
// "No authentication found" and the login screen; /login writes a full blob.
//
// Sync reads are filtered in place. Async reads fill the same 30 s cache the
// sync read serves from, so they are re-run through this file as a child
// (`--filter-read`), keeping the caller's stream and exit-code semantics.
// execFileSync / execSync call Node's internal spawnSync, so each is wrapped.

const CREDENTIAL_SERVICE = "Claude Code-credentials";

function isCredentialRead(parts) {
  const text = parts.filter((p) => typeof p === "string").join(" ");
  return text.includes("find-generic-password") && text.includes(CREDENTIAL_SERVICE) && /(^|\s)-w(\s|$)/.test(text);
}

/** Returns the text with an unusable `claudeAiOauth` removed, or null when nothing needed changing. */
function sanitizeCredentialText(text) {
  let parsed;
  try { parsed = JSON.parse(text); } catch { return null; }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const oauth = parsed.claudeAiOauth;
  if (!oauth || typeof oauth !== "object") return null;
  if (Array.isArray(oauth.scopes)) return null;
  delete parsed.claudeAiOauth;
  return JSON.stringify(parsed) + (/\n$/.test(text) ? "\n" : "");
}

/** `[file, args, options]` that re-runs the read through this file and filters it. */
function redirectedRead(file, args, options) {
  const payload = JSON.stringify({ file, args: args || [], shell: Boolean(options && options.shell) });
  return [process.execPath, [__filename, "--filter-read", payload], options ? { ...options, shell: false } : undefined];
}

function install(child_process, log) {
  function filterOutput(out) {
    if (out == null) return out;
    const isBuffer = Buffer.isBuffer(out);
    const cleaned = sanitizeCredentialText(isBuffer ? out.toString("utf8") : String(out));
    if (cleaned === null) return out;
    log("[keychain-guard] saved Claude login has no usable scopes; presenting it as logged out so /login can repair it");
    return isBuffer ? Buffer.from(cleaned, "utf8") : cleaned;
  }

  const origSpawnSync = child_process.spawnSync;
  child_process.spawnSync = function (command, args) {
    const result = origSpawnSync.apply(this, arguments);
    if (result && isCredentialRead([command, ...(Array.isArray(args) ? args : [])])) {
      result.stdout = filterOutput(result.stdout);
      if (Array.isArray(result.output) && result.output.length > 1) result.output[1] = result.stdout;
    }
    return result;
  };

  const origExecFileSync = child_process.execFileSync;
  child_process.execFileSync = function (file, args) {
    const out = origExecFileSync.apply(this, arguments);
    return isCredentialRead([file, ...(Array.isArray(args) ? args : [])]) ? filterOutput(out) : out;
  };

  const origExecSync = child_process.execSync;
  child_process.execSync = function (command) {
    const out = origExecSync.apply(this, arguments);
    return isCredentialRead([command]) ? filterOutput(out) : out;
  };

  const origSpawn = child_process.spawn;
  child_process.spawn = function (command, args, options) {
    if (!Array.isArray(args) || !isCredentialRead([command, ...args])) return origSpawn.apply(this, arguments);
    return origSpawn.apply(this, redirectedRead(command, args, options));
  };

  const origExecFile = child_process.execFile;
  child_process.execFile = function (file, args, ...rest) {
    if (!Array.isArray(args) || !isCredentialRead([file, ...args])) return origExecFile.apply(this, arguments);
    const options = rest[0] && typeof rest[0] === "object" ? rest.shift() : undefined;
    const [f, a, o] = redirectedRead(file, args, options);
    return origExecFile.call(this, f, a, o || {}, ...rest);
  };
  // promisify(execFile) must keep resolving to { stdout, stderr } for every other caller.
  child_process.execFile[util.promisify.custom] = origExecFile[util.promisify.custom];
}

// Child side of redirectedRead: run the original read, print it filtered, keep its exit status.
if (require.main === module && process.argv[2] === "--filter-read") {
  const { file, args, shell } = JSON.parse(process.argv[3]);
  const r = require("node:child_process").spawnSync(file, args, { shell, stdio: ["ignore", "pipe", "inherit"], timeout: 10000 });
  if (r.error) {
    process.stderr.write(`keychain-login-guard: ${r.error.message}\n`);
    process.exit(127);
  }
  const cleaned = sanitizeCredentialText(r.stdout.toString("utf8"));
  process.stdout.write(cleaned === null ? r.stdout : cleaned);
  process.exitCode = r.status ?? 1;
}

module.exports = { install, isCredentialRead, sanitizeCredentialText };
