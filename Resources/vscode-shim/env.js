"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { Uri } = require("./types.js");
const { writeStdout } = require("./protocol.js");

function createEnv({ machineIdPath, remoteName }) {
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

  return {
    appName: "Visual Studio Code", // extension may branch on this
    appRoot: "",
    uiKind: 1, // Desktop
    language: "en",
    machineId,
    sessionId: crypto.randomUUID(),
    shell: process.env.SHELL || "/bin/zsh",
    remoteName: remoteName || undefined,
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

module.exports = { createEnv };
