"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { EventEmitter } = require("./types.js");
const { writeStdout } = require("./protocol.js");

// VS Code's `env.isTelemetryEnabled` is true only at TelemetryLevel.USAGE.
// `telemetry.telemetryLevel` defaults to "all" (USAGE) when unset; "error",
// "crash", "off", and any other value are not usage. The legacy booleans
// force the level to NONE when explicitly false, and they win over the
// level. Mirrors `getTelemetryLevel` in VS Code's telemetryUtils.ts.
//
// CC 2.1.311 reads the flag in several places and, when it is falsy, spawns
// the CLI with DISABLE_TELEMETRY=1. That also turns off feature-flag fetch,
// so a missing flag (undefined is falsy) silently drops gated features.
// `onDidChangeTelemetryEnabled` is called during activate — a missing
// function throws and the shim exits before `ready`. The shim does not
// live-reload configuration (same as `onDidChangeConfiguration`), so the
// event is not fired for the life of the process; the value is whatever
// the settings layers said at startup. A hand edit of
// `telemetry.telemetryLevel` (or the legacy `telemetry.enableTelemetry` /
// `telemetry.enableCrashReporter`) in Canopy's settings.json or the
// workspace `.vscode/settings.json` is picked up on the next session.
function isTelemetryEnabledFromConfiguration(get) {
  if (get("telemetry.enableTelemetry") === false) return false;
  if (get("telemetry.enableCrashReporter") === false) return false;
  const level = get("telemetry.telemetryLevel");
  const resolved = level === undefined ? "all" : level;
  return resolved === "all";
}

function createEnv({ machineIdPath, remoteName, isTelemetryEnabled = true }) {
  // machineId: UUID persisted to file, created on first run
  let machineId;
  try {
    machineId = fs.readFileSync(machineIdPath, "utf-8").trim();
  } catch {
    machineId = crypto.randomUUID();
    const dir = path.dirname(machineIdPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(machineIdPath, machineId);
  }

  // Subscribed during activate. Nothing fires it: index.js reads the
  // settings once at startup, and the shim has no settings-changed channel.
  const onDidChangeTelemetryEnabled = new EventEmitter();

  return {
    appName: "Visual Studio Code", // extension may branch on this
    appRoot: "",
    uiKind: 1, // Desktop
    language: "en",
    machineId,
    sessionId: crypto.randomUUID(),
    shell: process.env.SHELL || "/bin/zsh",
    remoteName: remoteName || undefined,
    isTelemetryEnabled,
    onDidChangeTelemetryEnabled: onDidChangeTelemetryEnabled.event,
    clipboard: {
      readText: () => Promise.resolve(""),
      writeText: () => Promise.resolve(),
    },
    openExternal(uri) {
      writeStdout({ type: "open_url", url: typeof uri === "string" ? uri : uri.toString() });
      return Promise.resolve(true);
    },
  };
}

module.exports = { createEnv, isTelemetryEnabledFromConfiguration };
