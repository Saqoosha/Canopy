"use strict";

// The CLI's control channel, for what the extension never sends. `Query.setCwd` exists
// in extension.js (2.1.319) but nothing calls it, so the shim writes `set_cwd` itself.

const { StringDecoder } = require("node:string_decoder");

// `set_cwd` answered in about 0.2 s (measured); this long means no answer is coming.
const ANSWER_TIMEOUT_MS = 30000;

let cliChild = null;

// Only the CLI spawn carries `--input-format`; git, ripgrep and MCP do not.
function trackCliSpawn(child_process) {
  const origSpawn = child_process.spawn;
  child_process.spawn = function (command, args) {
    const child = origSpawn.apply(this, arguments);
    if (Array.isArray(args) && args.includes("--input-format")) cliChild = child;
    return child;
  };
}

// A child killed by a signal keeps `exitCode` null and sets `signalCode`.
function isRunning(child) {
  return Boolean(child && child.exitCode === null && child.signalCode == null
    && child.stdin && !child.stdin.destroyed && child.stdout);
}

function sendSetCwd({ requestId, path, trustedDirectory }, write, timeoutMs = ANSWER_TIMEOUT_MS) {
  const child = cliChild;
  if (!isRunning(child)) {
    write({ type: "set_cwd_result", requestId, error: "no running CLI" });
    return;
  }
  const controlId = `canopy-set-cwd-${requestId}`;
  const decoder = new StringDecoder("utf8");
  let buffer = "";
  // Where the last search for a newline stopped: one long line arrives in many chunks.
  let scanned = 0;
  let finished = false;
  let timer = null;
  const finish = (fields) => {
    if (finished) return;
    finished = true;
    clearTimeout(timer);
    child.stdout.off("data", onData);
    child.off("exit", onExit);
    write({ type: "set_cwd_result", requestId, ...fields });
  };
  const onExit = () => finish({ error: "the CLI exited" });
  const onData = (chunk) => {
    buffer += decoder.write(chunk);
    let start = 0;
    let newline;
    while ((newline = buffer.indexOf("\n", Math.max(start, scanned))) !== -1) {
      const line = buffer.slice(start, newline);
      start = newline + 1;
      if (!line.includes(controlId)) continue;
      let parsed;
      try { parsed = JSON.parse(line); } catch { continue; }
      if (parsed.type !== "control_response" || parsed.response?.request_id !== controlId) continue;
      finish({ response: parsed.response });
      return;
    }
    buffer = buffer.slice(start);
    scanned = buffer.length;
  };
  // Added here, not at spawn: a `data` listener starts the stream flowing, and at
  // spawn the extension would not be reading yet.
  child.stdout.on("data", onData);
  child.on("exit", onExit);
  timer = setTimeout(() => finish({ error: "no answer" }), timeoutMs);
  timer.unref?.();
  const request = { subtype: "set_cwd", path };
  if (trustedDirectory) {
    request.trust_accepted = true;
    request.trusted_directory = trustedDirectory;
  }
  child.stdin.write(JSON.stringify({ type: "control_request", request_id: controlId, request }) + "\n", (error) => {
    if (error) finish({ error: `the write failed: ${error.message}` });
  });
}

module.exports = { trackCliSpawn, sendSetCwd };
