"use strict";

const readline = require("node:readline");

let _writer = (data) => process.stdout.write(data);

function _setWriter(fn) { _writer = fn; }

function writeStdout(msg) {
  _writer(JSON.stringify(msg) + "\n");
}

function startStdinReader(handler, input) {
  const rl = readline.createInterface({ input: input || process.stdin, terminal: false });
  rl.on("line", (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      const msg = JSON.parse(trimmed);
      handler(msg);
    } catch {
      process.stderr.write(`[vscode-shim] Invalid JSON on stdin: ${trimmed.slice(0, 200)}\n`);
    }
  });
  return rl;
}

module.exports = { writeStdout, startStdinReader, _setWriter };
