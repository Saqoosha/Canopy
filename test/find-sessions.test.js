"use strict";

// Runs the real script against a fake home, with a real `rg`. Only `ssh` is faked.

const { test, describe, after } = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const SCRIPT = path.join(__dirname, "..", "Resources", "canopy-bridge", "skills", "find-session", "find_sessions.py");
// The system Python: 3.9 on macOS, and a version manager's shim would try to install Python
// under a fake HOME.
const PYTHON = "/usr/bin/python3";
const REAL_RG = spawnSync("sh", ["-c", "command -v rg"], { encoding: "utf8" }).stdout.trim();

const homes = [];

function makeHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "find-sessions-"));
  homes.push(home);
  return home;
}

after(() => homes.forEach((home) => fs.rmSync(home, { recursive: true, force: true })));

function user(text, extra = {}) {
  return {
    type: "user", entrypoint: "claude-vscode", cwd: "/work/project", timestamp: "2026-11-05T10:00:00.000Z",
    message: { role: "user", content: text }, ...extra,
  };
}

// Key order as in a real transcript: `type` comes after the message, so a search cannot find it
// by looking at the start of the line.
function assistant(text, extra = {}) {
  return {
    parentUuid: null, isSidechain: false,
    message: { role: "assistant", content: [{ type: "text", text }] },
    type: "assistant", timestamp: "2026-11-05T10:00:05.000Z", ...extra,
  };
}

// A prompt typed during a turn is stored only like this, never as a user record.
function queued(prompt, origin, commandMode = "prompt") {
  return {
    type: "attachment", timestamp: "2026-11-06T09:00:00.000Z", cwd: "/work/project",
    attachment: { type: "queued_command", prompt, commandMode, origin },
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
    encoding: "utf8", timeout: 20000, env: { ...process.env, HOME: home, TZ: "UTC", ...env },
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
[ "$1" = "--" ] && shift
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
    writeSession(home, "-work-project", "bbbb", [user("the keychain item")]);
    assert.deepEqual(ids(run(home, ["search", "keychain"])), ["bbbb"]);
  });

  test("ignores sidechain, meta and synthetic records", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("hello"),
      user("zebra one", { isMeta: true }),
      user("zebra two", { isSynthetic: true }),
      assistant("zebra three", { isSidechain: true }),
    ]);
    writeSession(home, "-work-project", "bbbb", [user("zebra")]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), ["bbbb"]);
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
    writeSession(home, "-work-project", "bbbb", [user("zebra")]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), ["bbbb"]);
  });

  test("reads the entrypoint past the first line", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [{ type: "summary", summary: "first line" }, user("zebra", { entrypoint: "sdk-cli" })]);
    writeSession(home, "-work-project", "bbbb", [user("zebra")]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), ["bbbb"]);
  });

  test("ignores machine text in a user record", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("start"),
      user("<task-notification>zebra</task-notification>"),
      user("[Request interrupted by user] zebra"),
    ]);
    writeSession(home, "-work-project", "bbbb", [user("zebra")]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), ["bbbb"]);
  });

  test("keeps a prompt that mentions a caveat", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("Small Caveat: the zebra")]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), ["aaaa"]);
  });

  test("finds a reply whose type comes after a long message", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("hello"), assistant(`${"x".repeat(5000)} zebra`)]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), ["aaaa"]);
  });

  test("survives a half-written line", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const file = path.join(home, ".claude", "projects", "-work-project", "aaaa.jsonl");
    fs.appendFileSync(file, '{"type":"user","message":{"content":"zebra');
    assert.equal(local(run(home, ["search", "zebra"])).ok, true);
    assert.equal(run(home, ["tail", "aaaa"]).ok, true);
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

  test("finds terms split across a prompt and a reply", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("the zebra"), assistant("キリンの話")]);
    assert.deepEqual(ids(run(home, ["search", "zebra", "キリン"])), ["aaaa"]);
  });

  test("requires every term in the conversation, not just in the file", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("the zebra"),
      { type: "attachment", attachment: { type: "hook", content: "giraffe" } },
    ]);
    assert.deepEqual(ids(run(home, ["search", "zebra", "giraffe"])), []);
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

  test("matches a word of five letters or more inside a longer word", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebrafish")]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), ["aaaa"]);
    assert.deepEqual(ids(run(home, ["search", "zebr"])), []);
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
    writeSession(home, "-work-project", "cccc", [user("call foo(bar now")]);
    const machine = local(run(home, ["search", "foo(bar"]));
    assert.equal(machine.ok, true, machine.error);
    assert.deepEqual(machine.sessions.map((session) => session.sessionId), ["cccc"]);
  });

  test("matches a short term that starts or ends with punctuation", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("we use C++17 here")]);
    writeSession(home, "-work-project", "bbbb", [user("edit app.env now")]);
    writeSession(home, "-work-project", "cccc", [user("see PR#407")]);
    assert.deepEqual(ids(run(home, ["search", "C++"])), ["aaaa"]);
    assert.deepEqual(ids(run(home, ["search", ".env"])), ["bbbb"]);
    assert.deepEqual(ids(run(home, ["search", "#407"])), ["cccc"]);
  });

  test("finds a term with a quote or a backslash", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user('the path C:\\Users is "quoted" here')]);
    assert.deepEqual(ids(run(home, ["search", "C:\\Users"])), ["aaaa"]);
    assert.deepEqual(ids(run(home, ["search", '"quoted" here'])), ["aaaa"]);
  });

  test("ignores a compaction summary", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("the zebra work"),
      user("This session is being continued from a previous conversation. zebra zebra", { isCompactSummary: true, isVisibleInTranscriptOnly: true }),
    ]);
    const session = local(run(home, ["search", "zebra"])).sessions[0];
    assert.deepEqual(session.hits, { zebra: 1 });
    assert.equal(session.lastPrompt, "the zebra work");
  });

  test("keeps a prompt that follows a context block", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [{
      type: "user", entrypoint: "claude-vscode", cwd: "/work/project", timestamp: "2026-11-05T10:00:00.000Z",
      message: { role: "user", content: [
        { type: "text", text: "<ide_opened_file>notes.md</ide_opened_file>" },
        { type: "text", text: "fix the zebra" },
      ] },
    }]);
    const session = local(run(home, ["search", "zebra"])).sessions[0];
    assert.equal(session.firstPrompt, "fix the zebra");
  });

  test("finds a prompt typed during a turn", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("start the work"),
      queued([{ type: "text", text: "FDF drone field" }], { kind: "human" }),
    ]);
    const session = local(run(home, ["search", "drone"])).sessions[0];
    assert.equal(session.lastPrompt, "FDF drone field");
    assert.equal(session.lastActive, "2026-11-06");
  });

  test("finds a queued prompt from before commandMode existed", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("start the work"),
      { type: "attachment", timestamp: "2026-05-01T09:00:00.000Z", attachment: { type: "queued_command", prompt: "old zebra" } },
    ]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), ["aaaa"]);
  });

  test("leaves out queued prompts no person typed", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("start the work"),
      queued("<task-notification>zebra</task-notification>", { kind: "task-notification" }, "task-notification"),
      queued("zebra from a peer", { kind: "peer", from: "uds:/tmp/x" }),
    ]);
    assert.deepEqual(ids(run(home, ["search", "zebra"])), []);
  });

  test("keeps a title the user set", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      { type: "custom-title", customTitle: "Mine" },
      user("zebra"),
      { type: "ai-title", aiTitle: "Auto" },
    ]);
    assert.equal(local(run(home, ["search", "zebra"])).sessions[0].title, "Mine");
  });

  test("searches --any in one pass over the logs", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const log = path.join(home, "rg-calls");
    const rg = writeFakeSsh(home, `case " $* " in *" -l "*) echo call >> "${log}";; esac\nexec "${REAL_RG}" "$@"`);
    assert.deepEqual(ids(run(home, ["search", "--any", "zebra", "giraffe"], { FIND_SESSIONS_RG: rg })), ["aaaa"]);
    assert.equal(fs.readFileSync(log, "utf8").trim().split("\n").length, 1);
  });

  test("stops at the deadline while rg is silent", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const rg = writeFakeSsh(home, `case " $* " in *" -l "*) exec "${REAL_RG}" "$@";; esac\nexec sleep 8`);
    const started = Date.now();
    const machine = local(run(home, ["search", "--timeout", "1", "zebra"], { FIND_SESSIONS_RG: rg }));
    assert.ok(Date.now() - started < 4000, "the search ran past its deadline");
    assert.equal(machine.truncated, true);
  });

  test("skips a transcript that disappears during the search", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writeSession(home, "-work-project", "bbbb", [user("zebra zebra")]);
    const doomed = path.join(home, ".claude", "projects", "-work-project", "bbbb.jsonl");
    const rg = writeFakeSsh(home, `case " $* " in *" -l "*) exec "${REAL_RG}" "$@";; esac\n"${REAL_RG}" "$@"\nrm -f "${doomed}"`);
    const machine = local(run(home, ["search", "zebra"], { FIND_SESSIONS_RG: rg }));
    assert.equal(machine.ok, true, machine.error);
    assert.deepEqual(machine.sessions.map((session) => session.sessionId), ["aaaa"]);
  });

  test("reports a failed rg", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const rg = writeFakeSsh(home, 'echo "regex parse error" >&2\nexit 2');
    const machine = local(run(home, ["search", "zebra"], { FIND_SESSIONS_RG: rg }));
    assert.equal(machine.ok, false);
    assert.match(machine.error, /regex parse error/);
  });

  test("reports an rg killed by a signal", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const rg = writeFakeSsh(home, "kill -9 $$");
    assert.equal(local(run(home, ["search", "zebra"], { FIND_SESSIONS_RG: rg })).ok, false);
  });

  test("marks a partial file list as truncated", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const rg = writeFakeSsh(home, `"${REAL_RG}" "$@"\ncase " $* " in *" -l "*) exit 2;; esac`);
    const machine = local(run(home, ["search", "zebra"], { FIND_SESSIONS_RG: rg }));
    assert.equal(machine.ok, true);
    assert.equal(machine.truncated, true);
    assert.deepEqual(machine.sessions.map((session) => session.sessionId), ["aaaa"]);
  });

  test("marks a second pass that dies as truncated", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const rg = writeFakeSsh(home, `case " $* " in *" -l "*) exec "${REAL_RG}" "$@";; esac\nexit 2`);
    assert.equal(local(run(home, ["search", "zebra"], { FIND_SESSIONS_RG: rg })).truncated, true);
  });

  test("reports a Mac with no transcripts", () => {
    const machine = local(run(makeHome(), ["search", "zebra"]));
    assert.equal(machine.ok, false);
    assert.match(machine.error, /no transcripts/);
  });

  test("says how many sessions matched past the limit", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writeSession(home, "-work-project", "bbbb", [user("zebra zebra")]);
    const machine = local(run(home, ["search", "--limit", "1", "zebra"]));
    assert.equal(machine.sessions.length, 1);
    assert.equal(machine.matched, 2);
  });

  test("reports an unreadable peer list", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writePeers(home, {});
    fs.writeFileSync(path.join(home, "Library", "Application Support", "Canopy", "settings.json"), "{ torn");
    const result = run(home, ["search", "--all", "zebra"]);
    assert.deepEqual(ids(result), ["aaaa"]);
    const row = result.machines.find((machine) => machine.machine !== "local");
    assert.equal(row.ok, false);
    assert.match(row.error, /settings/);
  });

  test("treats no settings file as no peers", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    assert.deepEqual(run(home, ["search", "--all", "zebra"]).machines.map((machine) => machine.machine), ["local"]);
  });

  test("rejects a peer answer that is not a result", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writePeers(home, { "PEER-1": "100.1.2.3:8770", "PEER-2": "100.1.2.4:8770" });
    const ssh = writeFakeSsh(home, 'case " $* " in *100.1.2.3*) echo "[1]";; *) echo "{}";; esac');
    const result = run(home, ["search", "--all", "zebra"], { FIND_SESSIONS_SSH: ssh });
    assert.deepEqual(ids(result), ["aaaa"]);
    assert.deepEqual(result.machines.filter((machine) => machine.machine !== "local").map((machine) => machine.ok), [false, false]);
  });

  test("reports an empty term", () => {
    const home = makeHome();
    const machine = local(run(home, ["search", ""]));
    assert.equal(machine.ok, false);
    assert.match(machine.error, /term/);
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
    const result = run(home, ["search", "zebra"]);
    assert.deepEqual(ids(result), ["bbbb", "aaaa"]);
    assert.deepEqual(local(result).sessions[0].hits, { zebra: 3 });
  });

  test("honors --limit", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writeSession(home, "-work-project", "bbbb", [user("zebra zebra")]);
    assert.deepEqual(ids(run(home, ["search", "--limit", "1", "zebra"])), ["bbbb"]);
  });

  test("refuses a limit below one", () => {
    const result = spawnSync(PYTHON, [SCRIPT, "search", "--limit", "0", "zebra"], { encoding: "utf8", env: { ...process.env, HOME: makeHome() } });
    assert.notEqual(result.status, 0);
  });

  test("dates a session in this Mac's time zone", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra", { timestamp: "2026-11-05T20:00:00.000Z" })]);
    assert.equal(local(run(home, ["search", "zebra"], { TZ: "Asia/Tokyo" })).sessions[0].lastActive, "2026-11-06");
  });

  test("reads every batch of files", () => {
    const home = makeHome();
    for (let index = 0; index < 501; index += 1) {
      writeSession(home, "-work-project", `s${index}`, [user("zebra")]);
    }
    assert.equal(local(run(home, ["search", "--limit", "1000", "zebra"])).sessions.length, 501);
  });

  test("ignores the user's ripgrep config", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("the R6 track")]);
    const config = path.join(home, "ripgreprc");
    fs.writeFileSync(config, "--fixed-strings\n");
    assert.deepEqual(ids(run(home, ["search", "r6"], { RIPGREP_CONFIG_PATH: config })), ["aaaa"]);
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

  test("keeps what it found when time runs out during the scan", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const rg = writeFakeSsh(home, `case " $* " in *" -l "*) exec "${REAL_RG}" "$@";; esac\n"${REAL_RG}" "$@"\nexec sleep 8`);
    const machine = local(run(home, ["search", "--timeout", "1", "zebra"], { FIND_SESSIONS_RG: rg }));
    assert.equal(machine.truncated, true);
    assert.deepEqual(machine.sessions.map((session) => session.sessionId), ["aaaa"]);
  });

  test("reports truncated when the file list runs out of time", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    const rg = writeFakeSsh(home, "exec sleep 8");
    const started = Date.now();
    const machine = local(run(home, ["search", "--timeout", "1", "zebra"], { FIND_SESSIONS_RG: rg }));
    assert.ok(Date.now() - started < 4000);
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
    assert.equal(peer.host, "100.1.2.3");
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
    // A cut in a long output must not lose whether this Mac was searched.
    assert.equal(Object.keys(peer).at(-1), "sessions");
  });

  test("refuses a peer address that ssh could read as an option", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writePeers(home, { "PEER-1": "-oProxyCommand=touch /tmp/owned:8770", "PEER-2": "-oBatchMode:8770" });
    const called = path.join(home, "ssh-was-called");
    const ssh = writeFakeSsh(home, `touch "${called}"`);
    const result = run(home, ["search", "--all", "zebra"], { FIND_SESSIONS_SSH: ssh });
    assert.equal(fs.existsSync(called), false);
    const peer = result.machines.find((machine) => machine.machine === "PEER-1");
    assert.equal(peer.ok, false);
    assert.match(peer.error, /address/);
    assert.equal(result.machines.find((machine) => machine.machine === "PEER-2").ok, false);
  });

  test("ends ssh options before the host", () => {
    const home = makeHome();
    writePeers(home, { "PEER-1": "100.1.2.3:8770" });
    const argv = path.join(home, "ssh-argv");
    const ssh = writeFakeSsh(home, `printf '%s\\n' "$@" > "${argv}"\nexit 255`);
    run(home, ["search", "--all", "zebra"], { FIND_SESSIONS_SSH: ssh });
    const words = fs.readFileSync(argv, "utf8").split("\n");
    assert.equal(words[words.indexOf("100.1.2.3") - 1], "--");
    assert.ok(words.includes("BatchMode=yes"), "ssh must not stop to ask for anything");
    assert.ok(words.some((word) => word.startsWith("ConnectTimeout=")));
  });

  test("reports a missing ssh", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    writePeers(home, { "PEER-1": "100.1.2.3:8770" });
    const result = run(home, ["search", "--all", "zebra"], { FIND_SESSIONS_SSH: "/nonexistent/ssh" });
    assert.deepEqual(ids(result), ["aaaa"]);
    assert.equal(result.machines.find((machine) => machine.machine === "PEER-1").ok, false);
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

  test("tail keeps the last reply of a turn and survives tool-only records", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("the prompt", { cwd: "/work/here" }),
      assistant("working on it"),
      { type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", name: "Bash" }] } },
      assistant("all done"),
    ]);
    const result = run(home, ["tail", "aaaa"]);
    assert.equal(result.cwd, "/work/here");
    assert.deepEqual(result.turns.map((turn) => [turn.prompt, turn.reply, turn.at]),
      [["the prompt", "all done", "2026-11-05T10:00:00.000Z"]]);
  });

  test("tail survives a reply before any prompt", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [assistant("orphan"), user("the prompt")]);
    assert.deepEqual(run(home, ["tail", "aaaa"]).turns.map((turn) => turn.prompt), ["the prompt"]);
  });

  test("tail refuses an id that leaves the projects folder", () => {
    const home = makeHome();
    fs.mkdirSync(path.join(home, ".claude", "projects", "-work-project"), { recursive: true });
    fs.writeFileSync(path.join(home, "outside.jsonl"), `${JSON.stringify(user("secret"))}\n`);
    assert.equal(run(home, ["tail", "../../../outside"]).ok, false);
  });

  test("tail reports an unknown machine", () => {
    const result = run(makeHome(), ["tail", "aaaa", "--machine", "NOPE"]);
    assert.equal(result.ok, false);
    assert.match(result.error, /NOPE/);
  });

  test("tail ignores the reply to a keep-alive", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("real prompt"),
      assistant("real reply"),
      user("[Canopy keep-alive] Prompt-cache refresh, no action needed."),
      assistant("Acknowledged."),
    ]);
    assert.deepEqual(run(home, ["tail", "aaaa"]).turns.map((turn) => turn.reply), ["real reply"]);
  });

  test("tail includes a prompt typed during a turn", () => {
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [
      user("first"),
      assistant("one"),
      queued([{ type: "text", text: "second" }], { kind: "human" }),
      assistant("two"),
    ]);
    assert.deepEqual(run(home, ["tail", "aaaa"]).turns.map((turn) => [turn.prompt, turn.reply]), [["first", "one"], ["second", "two"]]);
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

  test("tail reads the largest copy of a session", () => {
    const home = makeHome();
    writeSession(home, "-a-stub", "aaaa", [{ type: "summary", summary: "stub" }]);
    writeSession(home, "-z-real", "aaaa", [user("the real session"), assistant("a reply")]);
    const real = path.join(home, ".claude", "projects", "-z-real", "aaaa.jsonl");
    fs.utimesSync(real, new Date(1000), new Date(1000));
    assert.deepEqual(run(home, ["tail", "aaaa"]).turns.map((turn) => turn.prompt), ["the real session"]);
  });

  test("tail reports an unknown session", () => {
    const home = makeHome();
    const result = run(home, ["tail", "nope"]);
    assert.equal(result.ok, false);
    assert.match(result.error, /nope/);
  });
});

describe("SKILL.md", () => {
  test("its commands run", () => {
    const skill = fs.readFileSync(path.join(path.dirname(SCRIPT), "SKILL.md"), "utf8");
    const commands = skill.split("\n").map((line) => line.trim()).filter((line) => line.startsWith("python3 "));
    assert.equal(commands.length, 2);
    const home = makeHome();
    writeSession(home, "-work-project", "aaaa", [user("zebra")]);
    for (const command of commands) {
      const args = command.replace("python3 ", "").replace('"${CLAUDE_SKILL_DIR}/find_sessions.py" ', "")
        .replace("TERM...", "zebra").replace("SESSION_ID", "aaaa").replace("MACHINE", "local").split(" ");
      assert.notEqual(run(home, args).ok, false, command);
    }
  });
});
