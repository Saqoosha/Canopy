"use strict";

// The CLI's control channel, for what the extension never sends. `Query.setCwd` exists
// in extension.js but nothing calls it, so the shim writes `set_cwd` to the CLI's stdin.

const { StringDecoder } = require("node:string_decoder");

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

function sendSetCwd({ requestId, path, trustedDirectory }, write) {
  const child = cliChild;
  if (!child || child.exitCode !== null || !child.stdin || !child.stdout) {
    write({ type: "set_cwd_result", requestId, error: "no running CLI" });
    return;
  }
  const controlId = `canopy-set-cwd-${requestId}`;
  const decoder = new StringDecoder("utf8");
  let buffer = "";
  const stop = () => {
    child.stdout.off("data", onData);
    child.off("exit", onExit);
  };
  const onExit = () => {
    stop();
    write({ type: "set_cwd_result", requestId, error: "the CLI exited" });
  };
  const onData = (chunk) => {
    buffer += decoder.write(chunk);
    let newline;
    while ((newline = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line.includes(controlId)) continue;
      let parsed;
      try { parsed = JSON.parse(line); } catch { continue; }
      if (parsed.type !== "control_response" || parsed.response?.request_id !== controlId) continue;
      stop();
      write({ type: "set_cwd_result", requestId, response: parsed.response });
      return;
    }
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
  child.stdin.write(JSON.stringify({ type: "control_request", request_id: controlId, request }) + "\n");
}

module.exports = { trackCliSpawn, sendSetCwd };
