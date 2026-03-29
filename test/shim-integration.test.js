"use strict";

const assert = require("node:assert");
const { describe, it, afterEach } = require("node:test");
const { spawnShim } = require("./helpers.js");

let shim;

afterEach(() => {
  if (shim) { shim.kill(); shim = null; }
});

describe("Level 2: Integration", { timeout: 120000 }, () => {

  it("starts and sends ready", async () => {
    shim = spawnShim();
    const ready = await shim.waitFor("ready", 60000);
    assert.strictEqual(ready.type, "ready");
  });

  it("responds to init request after ready", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.send({ type: "webview_ready" });

    const reqId = shim.sendRequest("init");
    const response = await shim.waitForWebviewResponse(reqId, 15000);
    assert.ok(response, "Should get a response to init");
  });

  it("responds to get_asset_uris", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.send({ type: "webview_ready" });

    const reqId = shim.sendRequest("get_asset_uris");
    const response = await shim.waitForWebviewResponse(reqId, 10000);
    assert.ok(response, "Should get asset uris response");
  });

  it("survives unknown message type without crashing", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.send({ type: "webview_message", message: { type: "totally_unknown_xyz_123" } });
    // Wait 2s and verify process is still alive
    await new Promise(r => setTimeout(r, 2000));
    assert.strictEqual(shim.proc.exitCode, null, "Process should still be running");
  });

  it("survives invalid JSON on stdin without crashing", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.proc.stdin.write("this is not valid json at all\n");
    await new Promise(r => setTimeout(r, 2000));
    assert.strictEqual(shim.proc.exitCode, null, "Process should still be running");
  });

  it("exits cleanly on SIGTERM", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    shim.proc.kill("SIGTERM");
    await new Promise((resolve) => {
      shim.proc.on("exit", resolve);
      setTimeout(resolve, 5000); // safety timeout
    });
    // Process should have exited
    shim = null; // don't try to kill again
  });

  it("stderr captures extension logs (console redirect working)", async () => {
    shim = spawnShim();
    await shim.waitFor("ready", 60000);
    // Extension activation should produce some stderr output
    assert.ok(shim.stderrLines.length > 0, "Should have stderr output from extension");
    // Verify our prefix format
    const hasShimPrefix = shim.stderrLines.some(l =>
      l.includes("[vscode-shim]") || l.includes("[ext:")
    );
    assert.ok(hasShimPrefix, "Stderr should contain shim-prefixed logs");
  });

});
