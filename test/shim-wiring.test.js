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

test("CANOPY_CLI_CWD moves only the CLI spawn, not the extension's other children", async () => {
    const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "canopy-clicwd-")));
    try {
        const ext = path.join(dir, "ext");
        const cli = path.join(dir, "cli");
        fs.mkdirSync(ext);
        fs.mkdirSync(cli);
        fs.writeFileSync(path.join(ext, "package.json"), JSON.stringify({ name: "p", version: "0.0.0", main: "extension.js" }));
        fs.writeFileSync(path.join(ext, "extension.js"),
            "exports.activate = () => {\n"
            + "  const cp = require('child_process');\n"
            + `  cp.spawn('/bin/sh', ['-c', 'pwd -P > ${dir}/cli.txt', 'sh', '--input-format', 'stream-json'], { cwd: '${dir}' });\n`
            + `  cp.spawn('/bin/sh', ['-c', 'pwd -P > ${dir}/other.txt'], { cwd: '${dir}' });\n`
            + "};\n");
        spawnSync(process.execPath, [SHIM, "--extension-path", ext, "--cwd", dir,
            "--settings-path", path.join(dir, "settings.json")], {
            input: "", encoding: "utf-8", timeout: 30000,
            env: { ...process.env, HOME: dir, CANOPY_CLI_CWD: cli },
        });
        const read = async (name) => {
            for (let i = 0; i < 50; i++) {
                const file = path.join(dir, name);
                if (fs.existsSync(file) && fs.readFileSync(file, "utf-8").trim()) return fs.readFileSync(file, "utf-8").trim();
                await new Promise((r) => setTimeout(r, 100));
            }
            return null;
        };
        assert.equal(await read("cli.txt"), cli);
        assert.equal(await read("other.txt"), dir);
    } finally {
        fs.rmSync(dir, { recursive: true, force: true });
    }
});

/**
 * CC 2.1.311 reads `vscode.env.isTelemetryEnabled` and subscribes to
 * `onDidChangeTelemetryEnabled` during activate. A unit test of
 * `isTelemetryEnabledFromConfiguration` stays green if `index.js` stops
 * passing the value into `createEnv` — the default is telemetry on, which
 * is also what an omitted flag produces — so the "off" cases have to go
 * through the real process.
 */
function plantTelemetryExtension(dir) {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "package.json"), JSON.stringify({
        name: "telemetry-probe", version: "0.0.0", main: "extension.js",
    }));
    fs.writeFileSync(path.join(dir, "extension.js"),
        "const vscode = require('vscode');\n"
        + "exports.activate = (context) => {\n"
        + "  const sub = vscode.env.onDidChangeTelemetryEnabled(() => {});\n"
        + "  context.workspaceState.update('telemetryProbe', {\n"
        + "    isTelemetryEnabled: vscode.env.isTelemetryEnabled,\n"
        + "    subscribed: !!sub && typeof sub.dispose === 'function',\n"
        + "  });\n"
        + "};\n");
}

function probeTelemetry({ canopySettings, workspaceSettings } = {}) {
    const cwd = fs.mkdtempSync(path.join(os.tmpdir(), "canopy-telemetry-cwd-"));
    const home = fs.mkdtempSync(path.join(os.tmpdir(), "canopy-telemetry-home-"));
    const extensionPath = path.join(home, "ext");
    plantTelemetryExtension(extensionPath);
    const settingsPath = path.join(home, "settings.json");
    if (canopySettings) fs.writeFileSync(settingsPath, JSON.stringify(canopySettings));
    if (workspaceSettings) {
        fs.mkdirSync(path.join(cwd, ".vscode"), { recursive: true });
        fs.writeFileSync(path.join(cwd, ".vscode", "settings.json"), JSON.stringify(workspaceSettings));
    }
    const result = spawnSync(process.execPath, [
        SHIM,
        "--extension-path", extensionPath,
        "--cwd", cwd,
        "--settings-path", settingsPath,
    ], {
        input: "",
        encoding: "utf-8",
        env: { ...process.env, HOME: home },
        timeout: 30000,
    });
    try {
        if (result.status !== 0 || /Activation error/.test(result.stderr || "")) {
            assert.fail(`telemetry probe failed to activate: status=${result.status} stderr=${result.stderr}`);
        }
        const storagePath = path.join(home, "Library", "Application Support", "Canopy");
        const stateFile = workspaceStateFile(storagePath, cwd);
        assert.ok(fs.existsSync(stateFile), `no state file at ${stateFile}`);
        return JSON.parse(fs.readFileSync(stateFile, "utf-8")).telemetryProbe;
    } finally {
        fs.rmSync(cwd, { recursive: true, force: true });
        fs.rmSync(home, { recursive: true, force: true });
    }
}

test("index.js leaves telemetry on when the setting is unset, and the change event is subscribable", () => {
    const probe = probeTelemetry();
    assert.equal(probe.isTelemetryEnabled, true);
    assert.equal(probe.subscribed, true);
});

test("index.js maps telemetry.telemetryLevel 'error' to isTelemetryEnabled false", () => {
    // "error" is not "off", but VS Code's isTelemetryEnabled is USAGE only.
    // A wire that treated every level other than "off" as enabled stays green
    // on an "off" fixture and still ships DISABLE_TELEMETRY for the wrong reason.
    const probe = probeTelemetry({ canopySettings: { "telemetry.telemetryLevel": "error" } });
    assert.equal(probe.isTelemetryEnabled, false);
    assert.equal(probe.subscribed, true);
});

test("index.js reads telemetry.telemetryLevel from the workspace settings file", () => {
    const probe = probeTelemetry({ workspaceSettings: { "telemetry.telemetryLevel": "off" } });
    assert.equal(probe.isTelemetryEnabled, false);
});

test("Canopy settings win over the workspace telemetry level", () => {
    const probe = probeTelemetry({
        canopySettings: { "telemetry.telemetryLevel": "all" },
        workspaceSettings: { "telemetry.telemetryLevel": "off" },
    });
    assert.equal(probe.isTelemetryEnabled, true);
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
