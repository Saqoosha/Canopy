"use strict";

// The CLI's control channel, for what the extension never sends. `Query.setCwd` exists
// in extension.js (2.1.319) but nothing calls it, so the shim writes `set_cwd` itself.

const { StringDecoder } = require("node:string_decoder");

// Every CLI spawned, newest last. The extension also starts a short-lived one (cwd
// `untrusted-start`) after the session's, so "the last spawn" can be a dead process.
let cliChildren = [];
// The one the extension last wrote a user message to: the session's conversation.
let sessionChild = null;
const spares = new WeakSet();

const USER_LINE = '"type":"user"';
const SPARE_CWD = "untrusted-start";

function chunkText(chunk) {
  if (typeof chunk === "string") return chunk;
  if (chunk instanceof Uint8Array) return Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength).toString("utf8");
  return "";
}

// True when a line of `text` is a top-level user message; a nested one does not count.
function hasUserLine(text) {
  if (!text.includes(USER_LINE)) return false;
  return text.split("\n").some((line) => {
    if (!line.includes(USER_LINE)) return false;
    // A line split across writes does not parse; its first piece still starts this way.
    if (line.trimStart().startsWith(`{${USER_LINE}`)) return true;
    try { return JSON.parse(line)?.type === "user"; } catch { return false; }
  });
}

// Only the CLI spawn carries `--input-format`; git, ripgrep and MCP do not.
function trackCliSpawn(child_process) {
  const origSpawn = child_process.spawn;
  child_process.spawn = function (command, args, options) {
    const child = origSpawn.apply(this, arguments);
    if (Array.isArray(args) && args.includes("--input-format")) {
      cliChildren = cliChildren.filter(isRunning).concat(child);
      const cwd = options && options.cwd != null ? String(options.cwd) : "";
      if (cwd.replace(/[\\/]+$/, "").split(/[\\/]/).pop() === SPARE_CWD) spares.add(child);
      const stdin = child.stdin;
      if (stdin && typeof stdin.write === "function") {
        const origWrite = stdin.write;
        stdin.write = function (chunk) {
          if (sessionChild !== child && hasUserLine(chunkText(chunk))) {
            sessionChild = child;
            process.stderr.write(`[cli-control] session CLI is pid ${child.pid}\n`);
          }
          return origWrite.apply(this, arguments);
        };
      }
    }
    return child;
  };
}

// Before any user message, the newest running CLI that is not the spare: it has no conversation to move.
function cliForControl() {
  if (isRunning(sessionChild)) return sessionChild;
  return cliChildren.filter((child) => isRunning(child) && !spares.has(child)).pop() ?? null;
}

// A child killed by a signal keeps `exitCode` null and sets `signalCode`.
function isRunning(child) {
  return Boolean(child && child.exitCode === null && child.signalCode == null
    && child.stdin && !child.stdin.destroyed && !child.stdin.writableEnded && child.stdout);
}

function sendSetCwd({ requestId, path, trustedDirectory }, write) {
  const child = cliForControl();
  if (!child) {
    const running = cliChildren.filter(isRunning).length;
    write({ type: "set_cwd_result", requestId, error: `no running CLI (${cliChildren.length} spawned, ${running} running, none with a conversation)` });
    return;
  }
  const how = child === sessionChild ? "session" : "newest";
  process.stderr.write(`[cli-control] set_cwd ${requestId} -> pid ${child.pid} (${how})\n`);
  const controlId = `canopy-set-cwd-${requestId}`;
  const decoder = new StringDecoder("utf8");
  let buffer = "";
  // Where the last search for a newline stopped: one long line arrives in many chunks.
  let scanned = 0;
  let finished = false;
  const finish = (fields) => {
    if (finished) return;
    finished = true;
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
