"use strict";

const { describe, it } = require("node:test");
const assert = require("node:assert/strict");
const { Readable } = require("node:stream");

const { writeStdout, startStdinReader, _setWriter } = require("../Resources/vscode-shim/protocol.js");

describe("writeStdout", () => {
  it("writes JSON + newline", () => {
    let captured = "";
    _setWriter((data) => { captured += data; });

    writeStdout({ type: "hello", value: 42 });

    assert.equal(captured, '{"type":"hello","value":42}\n');
  });

  it("handles nested objects", () => {
    let captured = "";
    _setWriter((data) => { captured += data; });

    writeStdout({ a: { b: { c: [1, 2, 3] } } });

    assert.equal(captured, '{"a":{"b":{"c":[1,2,3]}}}\n');
  });
});

describe("startStdinReader", () => {
  it("parses valid JSON", async () => {
    const received = [];
    const input = new Readable({ read() {} });

    const rl = startStdinReader((msg) => { received.push(msg); }, input);

    input.push('{"type":"test","n":1}\n');
    input.push('{"type":"test","n":2}\n');
    input.push(null);

    await new Promise((resolve) => rl.on("close", resolve));

    assert.equal(received.length, 2);
    assert.deepEqual(received[0], { type: "test", n: 1 });
    assert.deepEqual(received[1], { type: "test", n: 2 });
  });

  it("skips invalid JSON lines", async () => {
    const received = [];
    const input = new Readable({ read() {} });

    // Capture stderr to verify warning
    const stderrChunks = [];
    const origStderrWrite = process.stderr.write;
    process.stderr.write = (chunk) => { stderrChunks.push(chunk); return true; };

    const rl = startStdinReader((msg) => { received.push(msg); }, input);

    input.push('not json at all\n');
    input.push('{"valid":true}\n');
    input.push('also {broken\n');
    input.push(null);

    await new Promise((resolve) => rl.on("close", resolve));

    // Restore stderr
    process.stderr.write = origStderrWrite;

    assert.equal(received.length, 1);
    assert.deepEqual(received[0], { valid: true });
    assert.equal(stderrChunks.length, 2);
    assert.match(stderrChunks[0], /Invalid JSON/);
  });
});
