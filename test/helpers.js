"use strict";

const { spawn } = require("node:child_process");
const readline = require("node:readline");
const path = require("node:path");
const fs = require("node:fs");

function findExtensionPath() {
  const dir = path.join(process.env.HOME, ".vscode", "extensions");
  const entries = fs.readdirSync(dir)
    .filter(e => e.startsWith("anthropic.claude-code-"))
    .sort();
  if (entries.length === 0) throw new Error("CC extension not found in ~/.vscode/extensions/");
  return path.join(dir, entries[entries.length - 1]);
}

function spawnShim(opts = {}) {
  const proc = spawn("node", [
    path.join(__dirname, "..", "Resources", "vscode-shim", "index.js"),
    "--extension-path", opts.extensionPath || findExtensionPath(),
    "--cwd", opts.cwd || "/tmp",
    ...(opts.resume ? ["--resume", opts.resume] : []),
    ...(opts.permissionMode ? ["--permission-mode", opts.permissionMode] : []),
  ], { stdio: ["pipe", "pipe", "pipe"] });

  const stdoutRl = readline.createInterface({ input: proc.stdout });
  const stderrLines = [];
  const messages = [];

  stdoutRl.on("line", (line) => {
    try { messages.push(JSON.parse(line)); } catch { /* skip non-JSON */ }
  });

  const stderrRl = readline.createInterface({ input: proc.stderr });
  stderrRl.on("line", (line) => stderrLines.push(line));

  function send(msg) {
    proc.stdin.write(JSON.stringify(msg) + "\n");
  }

  function waitFor(type, timeout = 30000) {
    return new Promise((resolve, reject) => {
      const start = Date.now();
      const check = () => {
        const idx = messages.findIndex(m => m.type === type);
        if (idx >= 0) {
          const msg = messages[idx];
          messages.splice(idx, 1);
          return resolve(msg);
        }
        if (Date.now() - start > timeout) {
          return reject(new Error(
            `Timeout (${timeout}ms) waiting for "${type}". ` +
            `Got types: [${messages.map(m => m.type).join(", ")}]. ` +
            `Stderr tail: ${stderrLines.slice(-5).join(" | ")}`
          ));
        }
        setTimeout(check, 100);
      };
      check();
    });
  }

  function waitForWebviewResponse(requestId, timeout = 30000) {
    return new Promise((resolve, reject) => {
      const start = Date.now();
      const check = () => {
        // Extension wraps responses as: { type: "webview_message", message: { type: "from-extension", message: { type: "response", requestId, ... } } }
        const idx = messages.findIndex(m => {
          if (m.type !== "webview_message") return false;
          // Direct response (flat)
          if (m.message?.type === "response" && m.message?.requestId === requestId) return true;
          // Wrapped in from-extension
          if (m.message?.type === "from-extension" &&
              m.message?.message?.type === "response" &&
              m.message?.message?.requestId === requestId) return true;
          return false;
        });
        if (idx >= 0) {
          const msg = messages[idx];
          messages.splice(idx, 1);
          // Extract the inner response regardless of wrapping
          const response = msg.message?.type === "from-extension"
            ? msg.message.message
            : msg.message;
          return resolve(response);
        }
        if (Date.now() - start > timeout) {
          return reject(new Error(
            `Timeout waiting for response to ${requestId}. ` +
            `Messages: [${messages.map(m => JSON.stringify(m).slice(0, 100)).join(", ")}]`
          ));
        }
        setTimeout(check, 100);
      };
      check();
    });
  }

  function sendRequest(requestType, payload = {}, channelId = "ch1") {
    const requestId = `test-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
    send({
      type: "webview_message",
      message: {
        type: "request",
        channelId,
        requestId,
        request: { type: requestType, ...payload },
      },
    });
    return requestId;
  }

  function kill() {
    try { proc.kill("SIGTERM"); } catch {}
  }

  return { proc, messages, stderrLines, send, waitFor, waitForWebviewResponse, sendRequest, kill };
}

module.exports = { spawnShim, findExtensionPath };
