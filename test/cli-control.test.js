"use strict";

const { test } = require("node:test");
const assert = require("node:assert");
const { EventEmitter } = require("node:events");

const modulePath = require.resolve("../Resources/vscode-shim/cli-control.js");

// A fresh module per test: it keeps the CLI child in module state.
function freshControl() {
  delete require.cache[modulePath];
  return require(modulePath);
}

function fakeChild() {
  const child = new EventEmitter();
  child.exitCode = null;
  child.stdout = new EventEmitter();
  child.stdin = { lines: [], write(line) { this.lines.push(line); } };
  return child;
}

function runningCli(control, child = fakeChild()) {
  const spawner = { spawn: () => child };
  control.trackCliSpawn(spawner);
  spawner.spawn("claude", ["--input-format", "stream-json"], {});
  return child;
}

const sentRequest = (child) => JSON.parse(child.stdin.lines[0]);

function responseLine(requestId, inner) {
  return JSON.stringify({
    type: "control_response",
    response: { subtype: "success", request_id: requestId, response: inner },
  }) + "\n";
}

test("writes one control_request line", () => {
  const control = freshControl();
  const child = runningCli(control);
  control.sendSetCwd({ requestId: "a", path: "/tmp/x" }, () => {});
  assert.strictEqual(child.stdin.lines.length, 1);
  assert.ok(child.stdin.lines[0].endsWith("\n"));
  const message = sentRequest(child);
  assert.strictEqual(message.type, "control_request");
  assert.deepStrictEqual(message.request, { subtype: "set_cwd", path: "/tmp/x" });
});

test("sends the trust fields only with trustedDirectory", () => {
  const control = freshControl();
  const child = runningCli(control);
  control.sendSetCwd({ requestId: "a", path: "/tmp/x/y", trustedDirectory: "/tmp/x" }, () => {});
  assert.deepStrictEqual(sentRequest(child).request, {
    subtype: "set_cwd",
    path: "/tmp/x/y",
    trust_accepted: true,
    trusted_directory: "/tmp/x",
  });
});

test("returns the matching control_response", () => {
  const control = freshControl();
  const child = runningCli(control);
  const results = [];
  control.sendSetCwd({ requestId: "a", path: "/tmp/x" }, (result) => results.push(result));
  const requestId = sentRequest(child).request_id;

  child.stdout.emit("data", Buffer.from('{"type":"assistant"}\nnot json\n'));
  child.stdout.emit("data", Buffer.from(responseLine("someone-else", { status: "ok" })));
  assert.deepStrictEqual(results, []);

  child.stdout.emit("data", Buffer.from(responseLine(requestId, { status: "ok", changed: true })));
  assert.strictEqual(results.length, 1);
  assert.strictEqual(results[0].type, "set_cwd_result");
  assert.strictEqual(results[0].requestId, "a");
  assert.deepStrictEqual(results[0].response.response, { status: "ok", changed: true });
});

test("handles a response split across chunks", () => {
  const control = freshControl();
  const child = runningCli(control);
  const results = [];
  control.sendSetCwd({ requestId: "a", path: "/tmp/大梁川" }, (result) => results.push(result));
  const line = Buffer.from(responseLine(sentRequest(child).request_id, { status: "ok", cwd: "/tmp/大梁川" }));
  // Inside a character: a chunk boundary does not respect UTF-8.
  const middle = line.indexOf(Buffer.from("大")) + 1;
  child.stdout.emit("data", line.subarray(0, middle));
  assert.deepStrictEqual(results, []);
  child.stdout.emit("data", line.subarray(middle));
  assert.strictEqual(results.length, 1);
  assert.strictEqual(results[0].response.response.cwd, "/tmp/大梁川");
});

test("stops listening after the response", () => {
  const control = freshControl();
  const child = runningCli(control);
  control.sendSetCwd({ requestId: "a", path: "/tmp/x" }, () => {});
  assert.strictEqual(child.stdout.listenerCount("data"), 1);
  child.stdout.emit("data", Buffer.from(responseLine(sentRequest(child).request_id, { status: "ok" })));
  assert.strictEqual(child.stdout.listenerCount("data"), 0);
  assert.strictEqual(child.listenerCount("exit"), 0);
});

test("reports an error without a running CLI", () => {
  const control = freshControl();
  const results = [];
  control.sendSetCwd({ requestId: "none", path: "/tmp/x" }, (result) => results.push(result));

  const child = runningCli(control);
  child.exitCode = 1;
  control.sendSetCwd({ requestId: "dead", path: "/tmp/x" }, (result) => results.push(result));

  assert.deepStrictEqual(results.map((result) => result.requestId), ["none", "dead"]);
  assert.ok(results.every((result) => result.type === "set_cwd_result" && result.error));
  assert.deepStrictEqual(child.stdin.lines, []);
});

test("reports an error when the CLI exits before it answers", () => {
  const control = freshControl();
  const child = runningCli(control);
  const results = [];
  control.sendSetCwd({ requestId: "a", path: "/tmp/x" }, (result) => results.push(result));
  child.emit("exit", 1);
  assert.strictEqual(results.length, 1);
  assert.ok(results[0].error);
  assert.strictEqual(child.stdout.listenerCount("data"), 0);
});

test("keeps the child that carries --input-format", () => {
  const control = freshControl();
  const cli = fakeChild();
  const git = fakeChild();
  const spawner = { spawn: (command) => (command === "git" ? git : cli) };
  control.trackCliSpawn(spawner);
  spawner.spawn("claude", ["--input-format", "stream-json"], {});
  spawner.spawn("git", ["status"], {});
  control.sendSetCwd({ requestId: "a", path: "/tmp/x" }, () => {});
  assert.strictEqual(cli.stdin.lines.length, 1);
  assert.deepStrictEqual(git.stdin.lines, []);
});
