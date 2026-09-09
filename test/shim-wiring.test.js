"use strict";

// End-to-end through the real `index.js`. `shim-unit.test.js` proves
// `workspaceStateFile` and `createExtensionContext` in isolation by calling them
// with hand-written arguments; neither would notice if `index.js` stopped passing
// `args.cwd`, or stopped passing `CANOPY_SSH_HOST`. Both mutations were measured
// to leave that suite entirely green, and the first of them reintroduces this
// PR's own bug — every shim start throws `workspacePath is required`, every
// session bounces to the launcher, and CI says nothing.
//
// `test/cjk-emphasis-wiring.test.js` exists for the identical reason one file
// over. The integration suite would catch the FIRST of those mutations — a shim
// that cannot start never reaches `ready` — but not the second: `helpers.js`
// passes no `env` and nothing there runs in SSH mode. It also needs the real CC
// extension in `~/.vscode/extensions` and is in `EXCLUDED_TEST_FILES`, so it
// never runs on CI either way.
//
// The shim is driven with a synthetic extension rather than the real one: what is
// under test is the wiring, and a synthetic `activate` writes a workspaceState key
// on demand with no version, no network and no auth. `HOME` is a scratch
// directory because `index.js` derives `storagePath` from it — the same reason
// the A/B recipe in CLAUDE.md's shim learnings uses one.

const { test } = require("node:test");
const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const { workspaceStateFile } = require("../Resources/vscode-shim/context.js");

const SHIM = path.join(__dirname, "..", "Resources", "vscode-shim", "index.js");
const WRITTEN = ["written-by-the-extension"];

/** A minimal extension whose `activate` writes one workspaceState key. */
function plantExtension(dir) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({
        name: "wiring-probe", version: "0.0.0", main: "extension.js",
    }));
    fs.writeFileSync(path.join(dir, "extension.js"),
        "exports.activate = (context) => {\n"
        + `  context.workspaceState.update("panelSessionIds", ${JSON.stringify(WRITTEN)});\n`
        + "};\n");
}

/**
 * Run the shim to completion against the synthetic extension and return the
 * scratch `storagePath` it wrote into. stdin is closed immediately, which the
 * shim treats as "Canopy went away" and exits on — so the synthetic `activate`
 * must stay SYNCHRONOUS. `index.js` starts its stdin reader before awaiting
 * activation, and an `activate` that awaited anything could lose the race and
 * write nothing, which would read here as broken wiring rather than a broken
 * fake.
 *
 * Cleans up after itself on failure; the callers own the directory once it is
 * returned.
 */
function runShim({ cwd, env = {} }) {
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "canopy-wiring-"));
    const extensionPath = path.join(home, "ext");
    plantExtension(extensionPath);

    const result = spawnSync(process.execPath, [
        SHIM,
        "--extension-path", extensionPath,
        "--cwd", cwd,
        "--settings-path", path.join(home, "settings.json"),
    ], {
        input: "",
        encoding: "utf-8",
        env: { ...process.env, HOME: home, ...env },
        timeout: 30000,
    });

    if (/Activation error/.test(result.stderr)) {
        fs.rmSync(home, { recursive: true, force: true });
        assert.fail(`synthetic extension failed to activate: ${result.stderr}`);
    }
    return { home, storagePath: path.join(home, "Library", "Application Support", "Canopy") };
}

test("index.js passes the session's own cwd through to workspaceState", () => {
    const cwd = "/tmp/canopy-wiring-workspace";
    const { home, storagePath } = runShim({ cwd });
    try {
        const expected = workspaceStateFile(storagePath, cwd);
        assert.ok(fs.existsSync(expected), `no state file at ${expected}`);
        assert.deepEqual(JSON.parse(fs.readFileSync(expected, "utf-8")).panelSessionIds, WRITTEN);
    } finally {
        fs.rmSync(home, { recursive: true, force: true });
    }
});

test("index.js passes CANOPY_SSH_HOST through, so a remote session gets its own file", () => {
    const cwd = "/tmp/canopy-wiring-workspace";
    const { home, storagePath } = runShim({ cwd, env: { CANOPY_SSH_HOST: "wiring-host" } });
    try {
        const remote = workspaceStateFile(storagePath, cwd, "wiring-host");
        const local = workspaceStateFile(storagePath, cwd);
        assert.notEqual(remote, local);
        assert.ok(fs.existsSync(remote), `no state file at ${remote}`);
        assert.ok(!fs.existsSync(local), "wrote the LOCAL file for a remote session");
    } finally {
        fs.rmSync(home, { recursive: true, force: true });
    }
});
