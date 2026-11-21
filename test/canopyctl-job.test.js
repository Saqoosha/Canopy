"use strict";

// `canopyctl job …` against a fake daemon socket: what request each form sends.

const { test } = require("node:test");
const assert = require("node:assert");
const net = require("node:net");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const CANOPYCTL = path.join(__dirname, "../Resources/canopy-bridge/bin/canopyctl");

// Answers hello, records every request, and replies with `result`.
function fakeDaemon(result = { ok: true }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cctl-"));
  const sock = path.join(dir, "d.sock");
  const requests = [];
  const server = net.createServer((conn) => {
    let buf = "";
    conn.on("data", (chunk) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf("\n")) >= 0) {
        const msg = JSON.parse(buf.slice(0, i));
        buf = buf.slice(i + 1);
        if (msg.type === "hello") conn.write(JSON.stringify({ type: "hello_ok" }) + "\n");
        if (msg.type === "request") {
          requests.push({ verb: msg.verb, params: msg.params });
          conn.write(JSON.stringify({ type: "response", id: msg.id, result }) + "\n");
        }
      }
    });
  });
  return new Promise((resolve) => server.listen(sock, () => resolve({ sock, requests, close: () => server.close() })));
}

function run(sock, args) {
  return new Promise((resolve) => {
    const child = spawn("python3", [CANOPYCTL, "--socket", sock, ...args]);
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code) => resolve({ code, out, err }));
  });
}

test("job watch sends job_watch with the spec", async () => {
  const d = await fakeDaemon();
  const r = await run(d.sock, ["job", "watch", "--session-id", "S", "--label", "L", "--probe", "P", "--host", "rt4090"]);
  d.close();
  assert.strictEqual(r.code, 0, r.err);
  assert.deepStrictEqual(d.requests, [
    { verb: "job_watch", params: { sessionId: "S", label: "L", probe: "P", host: "rt4090", interval: 150 } },
  ]);
});

test("job watch passes --total, --interval and --stall-minutes", async () => {
  const d = await fakeDaemon();
  const r = await run(d.sock, ["job", "watch", "--session-id", "S", "--label", "L", "--probe", "P",
    "--total", "1077", "--interval", "60", "--stall-minutes", "30"]);
  d.close();
  assert.strictEqual(r.code, 0, r.err);
  assert.deepStrictEqual(d.requests[0].params,
    { sessionId: "S", label: "L", probe: "P", total: 1077, interval: 60, stallMinutes: 30 });
});

test("job list and job clear send their verbs", async () => {
  const d = await fakeDaemon();
  await run(d.sock, ["job", "list", "--session-id", "S"]);
  await run(d.sock, ["job", "clear", "--session-id", "S"]);
  d.close();
  assert.deepStrictEqual(d.requests, [
    { verb: "job_list", params: { sessionId: "S" } },
    { verb: "job_clear", params: { sessionId: "S" } },
  ]);
});

test("job watch without --probe exits non-zero and sends nothing", async () => {
  const d = await fakeDaemon();
  const r = await run(d.sock, ["job", "watch", "--session-id", "S", "--label", "L"]);
  d.close();
  assert.notStrictEqual(r.code, 0);
  assert.deepStrictEqual(d.requests, []);
});
