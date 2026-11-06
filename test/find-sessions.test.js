"use strict";

// Runs the real script against a fake home, with a real `rg`. Only `ssh` is faked, and the
// fake keeps the part that matters: like ssh it hands the remaining words to a shell.

const { test, describe } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = path.join(__dirname, "..", "Resources", "canopy-bridge", "skills", "find-session", "find_sessions.py");
// The system Python: what a peer runs over ssh (3.9 on macOS), and a version manager's shim
// would try to install itself under a fake HOME.
const PYTHON = "/usr/bin/python3";

function makeHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "find-sessions-"));
}

function user(text, extra = {}) {
  return {
    type: "user", entrypoint: "claude-vscode", cwd: "/work/project", timestamp: "2026-11-05T10:00:00.000Z",
    message: { role: "user", content: text }, ...extra,
  };
}

function assistant(text, extra = {}) {
  return {
    type: "assistant", timestamp: "2026-11-05T10:00:05.000Z",
    message: { role: "assistant", content: [{ type: "text", text }] }, ...extra,
  };
}

function writeSession(home, folder, id, records) {
  const dir = path.join(home, ".claude", "projects", folder);
  fs.mkdirSync(dir, { recursive: true });
  const lines = records.map((record) => JSON.stringify({ sessionId: id, ...record }));
  fs.writeFileSync(path.join(dir, `${id}.jsonl`), `${lines.join("\n")}\n`);
}

function run(home, args, env = {}) {
  const result = spawnSync(PYTHON, [SCRIPT, ...args], {
    encoding: "utf8", timeout: 20000, env: { ...process.env, HOME: home, ...env },
  });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

function local(result) {
  return result.machines.find((machine) => machine.machine === "local");
}

function ids(result) {
  return local(result).sessions.map((session) => session.sessionId);
}

function writePeers(home, peers) {
  const dir = path.join(home, "Library", "Application Support", "Canopy");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "settings.json"), JSON.stringify({ "canopy.mirrorPeers": peers }));
}

function writeFakeSsh(home, body) {
  const file = path.join(home, "fake-ssh");
  fs.writeFileSync(file, `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  return file;
}

// ssh joins everything after the host with spaces and gives that one string to the remote shell.
const SSH_THAT_RUNS_A_SHELL = `
while [ "$1" = "-o" ]; do shift 2; done
shift
PATH="/usr/bin:$PATH" HOME="$FAKE_REMOTE_HOME" exec sh -c "$*"
`;

describe("find_sessions.py search", () => {
  test("finds a word that only appears in a reply", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      { type: "ai-title", aiTitle: "Contract review" },
      user("please check the document"),
      assistant("業務委託の契約書を確認した"),
      user("thanks", { timestamp: "2026-11-06T09:00:00.000Z" }),
    ]);
    const session = local(run(home, ["search", "契約"])).sessions[0];
    assert.equal(session.sessionId, "aaaa");
    assert.equal(session.title, "Contract review");
    assert.equal(session.cwd, "/work/project");
    assert.equal(session.lastActive, "2026-11-06");
    assert.deepEqual(session.hits, { "契約": 1 });
    assert.equal(session.firstPrompt, "please check the document");
    assert.equal(session.lastPrompt, "thanks");
    assert.equal(session.snippets[0].role, "assistant");
    assert.match(session.snippets[0].text, /契約書/);
  });

  test("ignores hook text and tool results", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("hello"),
      { type: "attachment", attachment: { type: "hook", content: "keychain notes" } },
      { type: "user", entrypoint: "claude-vscode", message: { role: "user", content: [{ type: "tool_result", content: "keychain output" }] } },
    ]);
    assert.deepEqual(ids(run(home, ["search", "keychain"])), []);
  });

  test("ignores sidechain, meta and synthetic records", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("hello"),
      user("zebra one", { isMeta: true }),
      user("zebra two", { isSynthetic: true }),
      assistant("zebra three", { isSidechain: true }),
    ]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), []);
  });

  test("ignores keep-alive prompts", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("find the zebra"),
      user("[Canopy keep-alive] Prompt-cache refresh, no action needed."),
    ]);
    assert.equal(local(run(home, ["search", "zebra"])).sessions[0].lastPrompt, "find the zebra");
  });

  test("leaves out automated sessions", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra", { entrypoint: "sdk-py" })]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), []);
  });

  test("excludes the asking session", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("where is the zebra session?")]);
    writeSession(home, "-work-project", "bbbb", [user("zebra work")]);
    assert.deepEqual(ids(run(home, ["search", "--exclude", "aaaa", "zebra"])), ["bbbb"]);
  });

  test("requires every term unless --any", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra and giraffe")]);
    writeSession(home, "-work-project", "bbbb", [user("zebra alone")]);
    assert.deepEqual(ids(run(home, ["search", "zebra", "giraffe"])), ["aaaa"]);
    assert.deepEqual(ids(run(home, ["search", "--any", "zebra", "giraffe"])).sort(), ["aaaa", "bbbb"]);
  });

  test("ignores case", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("the KeyChain item")]);
    assert.deepEqual(ids(run(home, ["search", "keychain"])), ["aaaa"]);
  });

  test("matches a short ascii term as a word", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("abcr6def")]);
    writeSession(home, "-work-project", "bbbb", [user("the R6 track")]);
    assert.deepEqual(ids(run(home, ["search", "r6"])), ["bbbb"]);
  });

  test("matches a short ascii term after a line break", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("first line\nR6 track")]);
    assert.deepEqual(ids(run(home, ["search", "r6"])), ["aaaa"]);
  });

  test("matches a short ascii term next to japanese", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("R6のトラック")]);
    assert.deepEqual(ids(run(home, ["search", "r6"])), ["aaaa"]);
  });

  test("treats a term as text, not a pattern", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("use C++ here")]);
    writeSession(home, "-work-project", "bbbb", [user("use CCC here")]);
    assert.deepEqual(ids(run(home, ["search", "C++"])), ["aaaa"]);
  });

  test("matches japanese inside a longer word", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("業務委託基本契約書の件")]);
    assert.deepEqual(ids(run(home, ["search", "契約"])), ["aaaa"]);
  });

  test("ranks the session with more hits first", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writeSession(home, "-work-project", "bbbb", [user("zebra zebra"), assistant("zebra")]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), ["bbbb", "aaaa"]);
  });

  test("honors --limit", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writeSession(home, "-work-project", "bbbb", [user("zebra zebra")]);
    assert.deepEqual(ids(run(home, ["search", "--limit", "1", "zebra"])), ["bbbb"]);
  });

  test("counts a symlinked project once", () => {
    const home = makeHome();
    writeSession(home, "-work-real", "aaaa", [user("zebra")]);
    const projects = path.join(home, ".claude", "projects");
    fs.symlinkSync(path.join(projects, "-work-real"), path.join(projects, "-work-link"));
    const outside = path.join(home, "elsewhere");
    fs.mkdirSync(outside);
    fs.writeFileSync(path.join(outside, "bbbb.jsonl"), `${JSON.stringify({ sessionId: "bbbb", ...user("zebra") })}\n`);
    fs.symlinkSync(outside, path.join(projects, "-work-outside"));
    const sessions = local(run(home, ["search", "zebra"])).sessions;
    assert.deepEqual(sessions.map((session) => session.sessionId).sort(), ["aaaa", "bbbb"]);
    assert.deepEqual(sessions.map((session) => session.hits.zebra), [1, 1]);
  });

  test("reports truncated when out of time", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const machine = local(run(home, ["search", "--timeout", "0", "zebra"]));
    assert.equal(machine.ok, true);
    assert.equal(machine.truncated, true);
  });

  test("reports a missing rg", () => {
    const home = makeHome();
    const machine = local(run(home, ["search", "zebra"], { FIND_SESSIONS_RG: "/nonexistent/rg" }));
    assert.equal(machine.ok, false);
    assert.match(machine.error, /rg/);
  });

  test("reports an unreachable peer without losing local results", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writePeers(home, { "PEER-1": "100.1.2.3:8770" });
    const ssh = writeFakeSsh(home, 'echo "connect timed out" >&2\nexit 255');
    const result = run(home, ["search", "--all", "zebra"], { FIND_SESSIONS_SSH: ssh });
    assert.deepEqual(ids(result), ["aaaa"]);
    const peer = result.machines.find((machine) => machine.machine === "PEER-1");
    assert.equal(peer.ok, false);
    assert.match(peer.error, /connect timed out/);
  });

  test("sends terms to a peer unchanged", () => {
    const home = makeHome();
    const remote = makeHome();
    writeSession(remote, "-work-remote", "cccc", [user("it's 契約 time")]);
    writePeers(home, { "PEER-1": "100.1.2.3:8770" });
    const ssh = writeFakeSsh(home, SSH_THAT_RUNS_A_SHELL);
    const result = run(home, ["search", "--all", "it's 契約"], { FIND_SESSIONS_SSH: ssh, FAKE_REMOTE_HOME: remote });
    const peer = result.machines.find((machine) => machine.machine === "PEER-1");
    assert.equal(peer.ok, true, peer.error);
    assert.deepEqual(peer.sessions.map((session) => session.sessionId), ["cccc"]);
  });

  test("searches only this Mac without --all", () => {
    const home = makeHome();
    writePeers(home, { "PEER-1": "100.1.2.3:8770" });
    const ssh = writeFakeSsh(home, "exit 255");
    assert.deepEqual(run(home, ["search", "zebra"], { FIND_SESSIONS_SSH: ssh }).machines.map((machine) => machine.machine), ["local"]);
  });
});

describe("find_sessions.py tail", () => {
  const turns = [
    user("first", { timestamp: "2026-11-05T10:00:00.000Z" }),
    assistant("one"),
    user("second", { timestamp: "2026-11-05T11:00:00.000Z" }),
    assistant("two"),
    user("third", { timestamp: "2026-11-05T12:00:00.000Z" }),
    assistant("three"),
  ];

  test("tail returns the last turns", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", turns);
    const result = run(home, ["tail", "aaaa", "--turns", "2"]);
    assert.equal(result.ok, true);
    assert.deepEqual(result.turns.map((turn) => [turn.prompt, turn.reply]), [["second", "two"], ["third", "three"]]);
  });

  test("tail reads a peer's session", () => {
    const home = makeHome();
    const remote = makeHome();
    writeSession(remote, "-work-remote", "cccc", turns);
    writePeers(home, { "PEER-1": "100.1.2.3:8770" });
    const ssh = writeFakeSsh(home, SSH_THAT_RUNS_A_SHELL);
    const result = run(home, ["tail", "cccc", "--machine", "PEER-1", "--turns", "1"], { FIND_SESSIONS_SSH: ssh, FAKE_REMOTE_HOME: remote });
    assert.deepEqual(result.turns.map((turn) => turn.prompt), ["third"]);
  });

  test("tail reports an unknown session", () => {
    const home = makeHome();
    const result = run(home, ["tail", "nope"]);
    assert.equal(result.ok, false);
    assert.match(result.error, /nope/);
  });
});
