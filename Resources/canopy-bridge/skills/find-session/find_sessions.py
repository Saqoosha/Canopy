#!/usr/bin/env python3
"""Finds Claude Code sessions by what was said in them, on this Mac and its paired Macs.

Stores nothing: every search reads the transcripts. Measured 2026-11-06 on 7.5 GB and 13.5 GB
with a warm file cache, a search takes 0.3-4 s, so an index would buy little. Most matches are
hook text and tool output rather than conversation (`keychain`: 579 human sessions, 62 once
only prompts and replies count), so each candidate line is parsed and judged.

Runs on Python 3.9, the macOS system python3.
"""

import argparse
import base64
import concurrent.futures
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime
from itertools import islice

# Longer lines are pasted images and huge tool results. A prompt sharing one is skipped too.
MAX_LINE_BYTES = 2_000_000
# Where the first record with an entrypoint sits. Older transcripts have none at all.
ENTRYPOINT_LINES = 200
SNIPPET_RADIUS = 80
MAX_SNIPPETS = 3
PROMPT_CHARS = 200
TAIL_PROMPT_CHARS = 500
TAIL_REPLY_CHARS = 2000
FILE_BATCH = 500
SHORT_TERM_LENGTH = 4
SSH_CONNECT_SECONDS = 6
# Past the deadline, reading titles still gets this long: a cut-off search owes what it found.
SUMMARY_GRACE_SECONDS = 5
RG_LOCATIONS = ("/opt/homebrew/bin/rg", "/usr/local/bin/rg")
REGEX_META = set("\\.+*?()|[]{}^$")
# A line holding none of these cannot be conversation. Anywhere in the line: a key can sit
# after a long message.
PROMPT_MARKS = (b'"type":"user"', b'"queued_command"')
CONVERSATION_MARKS = PROMPT_MARKS + (b'"type":"assistant"',)
KEEP_ALIVE = "[Canopy keep-alive]"
NOT_PROMPTS = ("<", "[Request", KEEP_ALIVE)
NOT_CONVERSATION = ("isSidechain", "isMeta", "isSynthetic", "isCompactSummary", "isVisibleInTranscriptOnly")
# Backs up the -- in call_peer: -oProxyCommand would run a command here.
SAFE_ADDRESS = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]*\Z")
# Goes into a path, so `../` must not get through.
SAFE_SESSION_ID = re.compile(r"[0-9A-Za-z-]+\Z")


def projects_root():
    return os.path.expanduser("~/.claude/projects")


def settings_path():
    return os.path.expanduser("~/Library/Application Support/Canopy/settings.json")


def find_rg():
    override = os.environ.get("FIND_SESSIONS_RG")
    if override:
        return override if os.path.exists(override) else None
    found = shutil.which("rg")
    if found:
        return found
    return next((path for path in RG_LOCATIONS if os.path.exists(path)), None)


def is_short_ascii(term):
    return term.isascii() and len(term) <= SHORT_TERM_LENGTH


def is_word_character(character):
    return character.isascii() and (character.isalnum() or character == "_")


def rg_pattern(term):
    """The pattern for raw JSON lines. A short term matches as a word, or `r6` hits base64.

    `rg -w` will not do: a line break in a raw line is the two characters `\\n`, so `line\\nR6`
    has no word boundary before the R, and `-w` treats Japanese as word characters, so it
    misses `R6のトラック`.
    """
    encoded = json.dumps(term, ensure_ascii=False)[1:-1]
    escaped = "".join("\\" + c if c in REGEX_META else c for c in encoded)
    if not is_short_ascii(term):
        return escaped
    # Only a word character has a boundary: `C++ here` has none after the plus.
    before = r"(?:\\[nrt]|(?-u:\b))" if is_word_character(term[0]) else ""
    after = r"(?-u:\b)" if is_word_character(term[-1]) else ""
    return before + escaped + after


def text_pattern(term):
    """The same match for decoded text, which has real line breaks."""
    escaped = re.escape(term)
    if is_short_ascii(term):
        if is_word_character(term[0]):
            escaped = r"(?<![0-9A-Za-z_])" + escaped
        if is_word_character(term[-1]):
            escaped += r"(?![0-9A-Za-z_])"
    return re.compile(escaped, re.IGNORECASE)


def text_blocks(content):
    if isinstance(content, str):
        return [content.strip()]
    if isinstance(content, list):
        return [b.get("text", "").strip() for b in content if isinstance(b, dict) and b.get("type") == "text"]
    return []


def is_real_prompt(text):
    return bool(text) and not text.startswith(NOT_PROMPTS)


def queued_prompt(record):
    """A prompt typed during a turn. Most are stored only as this attachment."""
    attachment = record.get("attachment") or {}
    origin = attachment.get("origin") or {}
    if (attachment.get("type") == "queued_command" and attachment.get("commandMode", "prompt") == "prompt"
            and origin.get("kind", "human") == "human"):
        return attachment.get("prompt")
    return None


def conversation_text(record):
    """(role, text) for a prompt or reply, else None."""
    kind = record.get("type")
    if kind == "attachment":
        content = queued_prompt(record)
        kind = "user"
    elif kind in ("user", "assistant"):
        content = (record.get("message") or {}).get("content")
    else:
        return None
    if any(record.get(flag) for flag in NOT_CONVERSATION):
        return None
    blocks = text_blocks(content)
    # Per block: the extension can send IDE context as a block of its own before the prompt.
    kept = [block for block in blocks if block and (kind == "assistant" or is_real_prompt(block))]
    return (kind, "\n".join(kept)) if kept else None


def is_automated(path):
    try:
        with open(path, "rb") as transcript:
            for line in islice(transcript, ENTRYPOINT_LINES):
                match = re.search(rb'"entrypoint":"([^"]+)"', line[:MAX_LINE_BYTES])
                if match:
                    return match.group(1).startswith(b"sdk-")
    except OSError:
        pass
    return False


def local_date(timestamp):
    try:
        return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d")
    except ValueError:
        return timestamp[:10]


def session_id(path):
    return os.path.basename(path)[: -len(".jsonl")]


def run_rg(args, cwd, deadline):
    """(stdout lines, whether every file was read), or None when out of time. rg exits 1 for no
    match, and 2 both when a file is unreadable, which still lists the rest, and when it could
    not search at all."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return None
    try:
        done = subprocess.run(args, cwd=cwd, capture_output=True, timeout=remaining)
    except subprocess.TimeoutExpired:
        return None
    if done.returncode not in (0, 1) and not (done.returncode == 2 and done.stdout):
        detail = done.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(detail or "rg exited %d" % done.returncode)
    lines = done.stdout.decode("utf-8", "surrogateescape").split("\n")
    return [line for line in lines if line], done.returncode != 2


def files_matching(rg, terms, root, deadline):
    """(transcripts holding any of the terms, whether every file was read), or None when out of
    time."""
    patterns = [arg for term in terms for arg in ("-e", rg_pattern(term))]
    args = [rg, "--no-config", "-l", "-L", "-a", "-i", "--no-ignore", "--max-depth", "2",
            "--glob", "*.jsonl", *patterns, "."]
    listed = run_rg(args, root, deadline)
    if listed is None:
        return None
    lines, complete = listed
    return {os.path.realpath(os.path.join(root, line)) for line in lines}, complete


def scan_lines(rg, terms, files, deadline, on_record):
    """Feeds matching lines to on_record(path, record). False if it did not read everything."""
    patterns = [arg for term in terms for arg in ("-e", rg_pattern(term))]
    complete = True
    for start in range(0, len(files), FILE_BATCH):
        args = [rg, "--no-config", "-L", "-a", "-i", "--no-line-number", "--with-filename", "--null",
                *patterns, "--", *files[start:start + FILE_BATCH]]
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        # A timer, not a check in the loop: reading blocks while rg finds nothing.
        watchdog = threading.Timer(max(0.0, deadline - time.monotonic()), process.kill)
        watchdog.start()
        try:
            for raw in process.stdout:
                if len(raw) > MAX_LINE_BYTES:
                    continue
                path, _, body = raw.partition(b"\0")
                if not any(mark in body for mark in CONVERSATION_MARKS):
                    continue
                try:
                    record = json.loads(body)
                except ValueError:
                    continue
                on_record(path.decode("utf-8", "surrogateescape"), record)
            status = process.wait()
        finally:
            watchdog.cancel()
            process.kill()
            process.wait()
        if status < 0:
            return False  # killed: out of time, or rg died
        complete = complete and status in (0, 1)
    return complete


SUMMARY_KEYS = ("title", "cwd", "firstPrompt", "lastPrompt", "lastActive")


def summarize(path, deadline):
    """(summary, whether the whole file was read). `lastActive` is the date of the last prompt."""
    summary = dict.fromkeys(SUMMARY_KEYS, "")
    custom_title = ai_title = ""
    finished = True
    with open(path, "rb") as transcript:
        for raw in transcript:
            if time.monotonic() > deadline:
                finished = False
                break
            if len(raw) > MAX_LINE_BYTES:
                continue
            if b'Title"' not in raw and not any(mark in raw for mark in PROMPT_MARKS):
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            kind = record.get("type")
            if kind == "custom-title":
                custom_title = record.get("customTitle") or custom_title
                continue
            if kind == "ai-title":
                ai_title = ai_title or record.get("aiTitle") or ""
                continue
            spoken = conversation_text(record)
            if not spoken or spoken[0] != "user":
                continue
            prompt = spoken[1][:PROMPT_CHARS].replace("\n", " ")
            summary["firstPrompt"] = summary["firstPrompt"] or prompt
            summary["lastPrompt"] = prompt
            summary["cwd"] = record.get("cwd") or summary["cwd"]
            summary["lastActive"] = local_date(record.get("timestamp", "")) or summary["lastActive"]
    summary["title"] = custom_title or ai_title or summary["firstPrompt"]
    return summary, finished


def modified(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def search_here(terms, match_any, exclude, limit, timeout):
    row = local_row()
    terms = [term for term in terms if term.strip()]
    if not terms:
        return {**row, "ok": False, "error": "no search term"}
    rg = find_rg()
    if rg is None:
        return {**row, "ok": False, "error": "rg (ripgrep) is not installed on this Mac"}
    root = projects_root()
    if not os.path.isdir(root):
        return {**row, "ok": False, "error": "no transcripts at " + root}
    deadline = time.monotonic() + timeout

    candidates = None
    every_file_read = True
    for group in [terms] if match_any else [[term] for term in terms]:
        found = files_matching(rg, group, root, deadline)
        if found is None:
            return {**row, "truncated": True}
        paths, complete = found
        every_file_read = every_file_read and complete
        candidates = paths if candidates is None else candidates & paths

    excluded = {value.lower() for value in exclude}
    files = []
    for path in sorted(candidates):
        if time.monotonic() > deadline:
            return {**row, "truncated": True}
        if session_id(path).lower() not in excluded and not is_automated(path):
            files.append(path)

    matchers = {term: text_pattern(term) for term in terms}
    hits = {}
    snippets = {}

    def on_record(path, record):
        spoken = conversation_text(record)
        if not spoken:
            return
        role, text = spoken
        for term, matcher in matchers.items():
            found = list(matcher.finditer(text))
            if not found:
                continue
            counts = hits.setdefault(path, dict.fromkeys(terms, 0))
            counts[term] += len(found)
            kept = snippets.setdefault(path, [])
            if len(kept) < MAX_SNIPPETS:
                start = max(0, found[0].start() - SNIPPET_RADIUS)
                excerpt = text[start:found[0].end() + SNIPPET_RADIUS].replace("\n", " ")
                kept.append({"role": role, "text": excerpt})

    finished = scan_lines(rg, terms, files, deadline, on_record)

    wanted = any if match_any else all
    matched = [path for path, counts in hits.items() if wanted(counts.values())]
    # mtime breaks ties here: the date of the last prompt is only known once a file is read.
    matched.sort(key=lambda path: (sum(hits[path].values()), modified(path)), reverse=True)

    sessions = []
    summary_deadline = max(deadline, time.monotonic() + SUMMARY_GRACE_SECONDS)
    for path in matched[:limit]:
        summary = dict.fromkeys(SUMMARY_KEYS, "")
        if time.monotonic() > summary_deadline:
            finished = False
        else:
            try:
                summary, read_all = summarize(path, summary_deadline)
                finished = finished and read_all
            except FileNotFoundError:
                continue  # removed since rg read it, as when a worktree is cleaned up
            except OSError:
                finished = False  # the hits are real, so the row stays with no summary
        sessions.append({"sessionId": session_id(path), **summary, "hits": hits[path], "snippets": snippets[path]})
    sessions.sort(key=lambda session: (sum(session["hits"].values()), session["lastActive"]), reverse=True)
    return {**row, "truncated": not (finished and every_file_read), "matched": len(matched), "sessions": sessions}


def is_keep_alive(record):
    content = (record.get("message") or {}).get("content")
    return record.get("type") == "user" and any(block.startswith(KEEP_ALIVE) for block in text_blocks(content))


def tail_here(wanted_id, turns):
    if not SAFE_SESSION_ID.match(wanted_id):
        return {"ok": False, "error": "not a session id: " + wanted_id}
    root = projects_root()
    folders = os.listdir(root) if os.path.isdir(root) else []
    copies = [os.path.join(root, folder, wanted_id + ".jsonl") for folder in folders]
    copies = [copy for copy in copies if os.path.exists(copy)]
    if not copies:
        return {"ok": False, "error": "no transcript for " + wanted_id}
    # The same id can sit in two folders, and one can be a near-empty stub.
    path = max(copies, key=os.path.getsize)
    found = []
    cwd = ""
    answering = False
    with open(path, "rb") as transcript:
        for raw in transcript:
            if len(raw) > MAX_LINE_BYTES:
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            if is_keep_alive(record):
                answering = False
                continue
            spoken = conversation_text(record)
            if not spoken:
                continue
            role, text = spoken
            if role == "user":
                cwd = record.get("cwd") or cwd
                found.append({"prompt": text[:TAIL_PROMPT_CHARS], "reply": "", "at": record.get("timestamp", "")})
                answering = True
            elif answering:
                found[-1]["reply"] = text[-TAIL_REPLY_CHARS:]
    return {"ok": True, "sessionId": wanted_id, "cwd": cwd, "turns": found[-turns:]}


def load_peers():
    """(machine id -> IP for the paired Macs, or {}, and why they are unknown, or None).

    Only a missing file means no peers: a torn or unreadable one must not read as "no other Macs".
    """
    try:
        with open(settings_path(), encoding="utf-8") as settings:
            peers = json.load(settings).get("canopy.mirrorPeers") or {}
        return {machine: address.rsplit(":", 1)[0] for machine, address in peers.items()}, None
    except FileNotFoundError:
        return {}, None
    except (OSError, ValueError, AttributeError) as error:
        return {}, "could not read the paired Macs from settings.json: %s" % error


def ask_peer(address, request, timeout):
    """Never raises: a failure here must not take this Mac's answer with it."""
    try:
        return call_peer(address, request, timeout)
    except Exception as error:
        return {"ok": False, "error": "%s: %s" % (type(error).__name__, error)}


def call_peer(address, request, timeout):
    """Runs this script on a peer, or returns {"ok": False, "error": ...}.

    Arguments cross a remote shell that may be fish or zsh, so they travel as one base64 word
    rather than being quoted for either.
    """
    if not SAFE_ADDRESS.match(address):
        return {"ok": False, "error": "refusing the peer address %r" % address}
    payload = base64.b64encode(json.dumps(request).encode("utf-8")).decode("ascii")
    ssh = os.environ.get("FIND_SESSIONS_SSH") or "ssh"
    args = [ssh, "-o", "BatchMode=yes", "-o", "ConnectTimeout=%d" % SSH_CONNECT_SECONDS,
            "--", address, "python3", "-", "--b64", payload]
    with open(os.path.abspath(__file__), "rb") as source:
        script = source.read()
    try:
        done = subprocess.run(args, input=script, capture_output=True,
                              timeout=timeout + SUMMARY_GRACE_SECONDS + SSH_CONNECT_SECONDS + 5)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "no answer from %s: it may be down, or ssh may be waiting for an approval" % address}
    except OSError as error:
        return {"ok": False, "error": str(error)}
    if done.returncode != 0:
        detail = done.stderr.decode("utf-8", "replace").strip()
        return {"ok": False, "error": detail or "ssh exited %d" % done.returncode}
    try:
        result = json.loads(done.stdout)
    except ValueError:
        result = None
    if not isinstance(result, dict) or "ok" not in result:
        return {"ok": False, "error": "unreadable answer from " + address}
    return result


def local_row():
    return {"machine": "local", "host": socket.gethostname().split(".")[0], "ok": True, "truncated": False,
            "matched": 0, "sessions": []}


def peer_row(machine, address, result):
    """Status before sessions: a cut in a long output must not lose whether a Mac was searched."""
    rest = {key: value for key, value in result.items() if key not in ("machine", "host")}
    return {"machine": machine, "host": result.get("host") or address, **rest}


def handle(request):
    """Never raises: a failure here must not take the other Macs' answers with it."""
    try:
        if request["command"] == "tail":
            return tail_here(request["sessionId"], request["turns"])
        return search_here(request["terms"], request["any"], request["exclude"], request["limit"], request["timeout"])
    except Exception as error:
        return {**local_row(), "ok": False, "error": "%s: %s" % (type(error).__name__, error)}


def search_everywhere(request, use_peers):
    if not use_peers:
        return {"machines": [handle(request)]}
    peers, unknown = load_peers()
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(peers) + 1) as pool:
        here = pool.submit(handle, request)
        asked = {machine: (address, pool.submit(ask_peer, address, request, request["timeout"]))
                 for machine, address in peers.items()}
        rows = [here.result()]
        for machine, (address, future) in asked.items():
            rows.append(peer_row(machine, address, future.result()))
    if unknown:
        rows.append({"machine": "settings", "host": "", "ok": False, "error": unknown})
    return {"machines": rows}


def emit(result):
    """Bytes, because a lone surrogate in a transcript cannot go through a text stdout."""
    text = json.dumps(result, ensure_ascii=False) + "\n"
    sys.stdout.buffer.write(text.encode("utf-8", "replace"))


def positive_int(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be 1 or more")
    return number


def main(argv):
    if argv[:1] == ["--b64"]:
        emit(handle(json.loads(base64.b64decode(argv[1]))))
        return

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    search = commands.add_parser("search")
    search.add_argument("terms", nargs="+", metavar="TERM")
    search.add_argument("--all", action="store_true", help="also search the paired Macs")
    search.add_argument("--any", action="store_true", help="any term instead of every term")
    search.add_argument("--exclude", action="append", default=[], metavar="ID")
    search.add_argument("--limit", type=positive_int, default=15)
    search.add_argument("--timeout", type=float, default=40)
    tail = commands.add_parser("tail")
    tail.add_argument("session_id", metavar="SESSION_ID")
    tail.add_argument("--machine", default="local", metavar="MACHINE_ID")
    tail.add_argument("--turns", type=positive_int, default=3)
    args = parser.parse_args(argv)

    if args.command == "tail":
        request = {"command": "tail", "sessionId": args.session_id, "turns": args.turns}
        peers, unknown = load_peers()
        if args.machine == "local":
            result = handle(request)
        elif args.machine in peers:
            result = ask_peer(peers[args.machine], request, 30)
        else:
            result = {"ok": False, "error": unknown or "unknown machine " + args.machine}
    else:
        exclude = args.exclude + [value for value in [os.environ.get("CLAUDE_CODE_SESSION_ID")] if value]
        request = {"command": "search", "terms": args.terms, "any": args.any, "exclude": exclude,
                   "limit": args.limit, "timeout": args.timeout}
        result = search_everywhere(request, args.all)
    emit(result)


if __name__ == "__main__":
    main(sys.argv[1:])
