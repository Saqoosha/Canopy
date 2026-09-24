"use strict";

// A damaged Claude login must read as "logged out", not crash the shim.
//
// Measured on studio 2026-09-24: the Keychain item "Claude Code-credentials"
// had lost `scopes` (only accessToken / refreshToken / expiresAt were left).
// Extension 2.1.281's getAuthStatus does `tokens.scopes.includes(...)` with no
// guard, so every session died inside resolveWebviewView before the webview
// existed — and with no webview there was no way to reach /login and repair
// the blob. Dropping the unusable `claudeAiOauth` from what the extension
// reads makes it take its own "No authentication found" path and render the
// login screen; /login then writes a complete blob through `security
// add-generic-password`, which this guard never touches.
//
// Only the SYNC exec family is wrapped. getAuthStatus and saveOAuthTokens read
// through a sync store (execa sync → child_process.spawnSync), and the async
// readers already tolerate a missing `scopes`. Node's execFileSync / execSync
// call the module-internal spawnSync, not the export, so each is wrapped too.

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

function install(child_process, log) {
  function filterOutput(out) {
    if (out == null) return out;
    const isBuffer = Buffer.isBuffer(out);
    const cleaned = sanitizeCredentialText(isBuffer ? out.toString("utf8") : String(out));
    if (cleaned === null) return out;
    log("[keychain-guard] saved Claude login has no scopes; presenting it as logged out so /login can repair it");
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
}

module.exports = { install, isCredentialRead, sanitizeCredentialText };
