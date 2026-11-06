#!/usr/bin/env python3
"""Finds Claude Code sessions by what was said in them, on this Mac and its paired Macs.

Stores nothing: every search reads the transcripts with ripgrep. Measured 2026-11-06 on 7.5 GB
and 13.5 GB of transcripts, `rg -l` over everything takes 0.16-0.31 s with a warm file cache,
so an index would buy little. Most matches are hook text and tool output rather than
conversation (`keychain`: 579 human sessions, 62 once only prompts and replies count), so
each candidate line is parsed and judged.

Runs on Python 3.9, the system python3 on the other end of ssh.
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
import time
from datetime import datetime

# Longer lines are pasted images and huge tool results, never conversation worth reading.
MAX_LINE_BYTES = 2_000_000
SNIPPET_RADIUS = 80
MAX_SNIPPETS = 3
PROMPT_CHARS = 200
TAIL_PROMPT_CHARS = 500
TAIL_REPLY_CHARS = 2000
FILE_BATCH = 500
SHORT_TERM_LENGTH = 4
SSH_CONNECT_SECONDS = 6
RG_LOCATIONS = ("/opt/homebrew/bin/rg", "/usr/local/bin/rg")
REGEX_META = set("\\.+*?()|[]{}^$")
NOT_PROMPTS = ("<", "[Request", "[Canopy keep-alive]")


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
    """The pattern for raw JSON lines. A short term matches as a word, or `r6` hits every hash.

    `rg -w` will not do: a line break in a raw line is the two characters `\\n`, so `line\\nR6`
    has no word boundary before the R, and `-w` treats Japanese as word characters, so it
    misses `R6のトラック`.
    """
    escaped = "".join("\\" + c if c in REGEX_META else c for c in term)
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
        escaped = r"(?<![0-9A-Za-z_])" + escaped + r"(?![0-9A-Za-z_])"
    return re.compile(escaped, re.IGNORECASE)


def record_text(record):
    content = (record.get("message") or {}).get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
        return "\n".join(parts).strip()
    return ""


def is_real_prompt(text):
    return bool(text) and not text.startswith(NOT_PROMPTS) and "Caveat:" not in text[:20]


def conversation_text(record):
    """(role, text) when the record is something a person or the main model said, else None."""
    kind = record.get("type")
    if kind not in ("user", "assistant"):
        return None
    if record.get("isSidechain") or record.get("isMeta") or record.get("isSynthetic"):
        return None
    text = record_text(record)
    if kind == "user" and not is_real_prompt(text):
        return None
    return (kind, text) if text else None


def is_automated(path):
    try:
        with open(path, "rb") as transcript:
            for line in transcript:
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
    """stdout lines, or None when out of time. rg exits 1 for no match and 2 for a partly
    unreadable tree; both still leave a usable list."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return None
    try:
        done = subprocess.run(args, cwd=cwd, capture_output=True, timeout=remaining)
    except subprocess.TimeoutExpired:
        return None
    return done.stdout.decode("utf-8", "surrogateescape").splitlines()


def files_matching(rg, term, root, deadline):
    args = [rg, "--no-config", "-l", "-L", "-a", "-i", "--no-ignore", "--max-depth", "2",
            "--glob", "*.jsonl", "-e", rg_pattern(term), "."]
    lines = run_rg(args, root, deadline)
    if lines is None:
        return None
    return {os.path.realpath(os.path.join(root, line)) for line in lines}


def scan_lines(rg, terms, files, deadline, on_record):
    """Feeds every matching line that parses to on_record(path, record). False when out of time."""
    patterns = [arg for term in terms for arg in ("-e", rg_pattern(term))]
    for start in range(0, len(files), FILE_BATCH):
        args = [rg, "--no-config", "-L", "-a", "-i", "--no-line-number", "--with-filename", "--null",
                *patterns, "--", *files[start:start + FILE_BATCH]]
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            for count, raw in enumerate(process.stdout):
                if count % 256 == 0 and time.monotonic() > deadline:
                    return False
                if len(raw) > MAX_LINE_BYTES:
                    continue
                path, _, body = raw.partition(b"\0")
                # Anywhere in the line: the key can sit after a long message.
                if b'"type":"user"' not in body and b'"type":"assistant"' not in body:
                    continue
                try:
                    record = json.loads(body)
                except ValueError:
                    continue
                on_record(path.decode("utf-8", "surrogateescape"), record)
        finally:
            process.kill()
            process.wait()
    return True


def summarize(path):
    """Title, cwd, first and last prompt, and date of the last prompt."""
    summary = {"title": "", "cwd": "", "firstPrompt": "", "lastPrompt": "", "lastActive": ""}
    with open(path, "rb") as transcript:
        for raw in transcript:
            if len(raw) > MAX_LINE_BYTES:
                continue
            if b'"title"' not in raw and b'Title"' not in raw and b'"type":"user"' not in raw:
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            kind = record.get("type")
            if kind == "custom-title" or kind == "ai-title":
                summary["title"] = record.get("customTitle") or record.get("aiTitle") or summary["title"]
                continue
            spoken = conversation_text(record)
            if not spoken or spoken[0] != "user":
                continue
            prompt = spoken[1][:PROMPT_CHARS].replace("\n", " ")
            summary["firstPrompt"] = summary["firstPrompt"] or prompt
            summary["lastPrompt"] = prompt
            summary["cwd"] = record.get("cwd") or summary["cwd"]
            summary["lastActive"] = local_date(record.get("timestamp", "")) or summary["lastActive"]
    summary["title"] = summary["title"] or summary["firstPrompt"]
    return summary


def search_here(terms, match_any, exclude, limit, timeout):
    row = {"machine": "local", "host": socket.gethostname().split(".")[0], "ok": True, "truncated": False,
           "sessions": []}
    rg = find_rg()
    if rg is None:
        return {**row, "ok": False, "error": "rg (ripgrep) is not installed on this Mac"}
    root = projects_root()
    if not os.path.isdir(root):
        return row
    deadline = time.monotonic() + timeout

    candidates = None
    for term in terms:
        found = files_matching(rg, term, root, deadline)
        if found is None:
            return {**row, "truncated": True}
        if candidates is None:
            candidates = found
        else:
            candidates = candidates | found if match_any else candidates & found

    excluded = {value.lower() for value in exclude}
    files = sorted(path for path in candidates or ()
                   if session_id(path).lower() not in excluded and not is_automated(path))

    matchers = {term: text_pattern(term) for term in terms}
    hits = {}
    snippets = {}

    def on_record(path, record):
        spoken = conversation_text(record)
        if not spoken:
            return
        role, text = spoken
        path = os.path.realpath(path)
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
    # mtime breaks ties for now: the date of the last prompt is only known once a file is read.
    matched.sort(key=lambda path: (sum(hits[path].values()), os.path.getmtime(path)), reverse=True)

    sessions = []
    for path in matched[:limit]:
        if time.monotonic() > deadline:
            finished = False
            break
        sessions.append({"sessionId": session_id(path), **summarize(path),
                         "hits": hits[path], "snippets": snippets[path]})
    sessions.sort(key=lambda session: (sum(session["hits"].values()), session["lastActive"]), reverse=True)
    return {**row, "truncated": not finished, "sessions": sessions}


def tail_here(wanted_id, turns):
    root = projects_root()
    paths = [os.path.join(root, folder, wanted_id + ".jsonl") for folder in sorted(os.listdir(root))] \
        if os.path.isdir(root) else []
    path = next((candidate for candidate in paths if os.path.exists(candidate)), None)
    if path is None:
        return {"ok": False, "error": "no transcript for " + wanted_id}
    found = []
    cwd = ""
    with open(path, "rb") as transcript:
        for raw in transcript:
            if len(raw) > MAX_LINE_BYTES:
                continue
            try:
                record = json.loads(raw)
            except ValueError:
                continue
            spoken = conversation_text(record)
            if not spoken:
                continue
            role, text = spoken
            if role == "user":
                cwd = record.get("cwd") or cwd
                found.append({"prompt": text[:TAIL_PROMPT_CHARS], "reply": "", "at": record.get("timestamp", "")})
            elif found:
                found[-1]["reply"] = text[-TAIL_REPLY_CHARS:]
    return {"ok": True, "sessionId": wanted_id, "cwd": cwd, "turns": found[-turns:]}


def load_peers():
    """machine id -> IP, from the Macs this one is paired with."""
    try:
        with open(settings_path(), encoding="utf-8") as settings:
            peers = json.load(settings).get("canopy.mirrorPeers") or {}
    except (OSError, ValueError):
        return {}
    return {machine: address.rsplit(":", 1)[0] for machine, address in peers.items()}


def ask_peer(address, request, timeout):
    """Runs this script on a peer, or returns {"ok": False, "error": ...}.

    Arguments cross a remote shell that may be fish or zsh, so they travel as one base64 word
    rather than being quoted for either.
    """
    payload = base64.b64encode(json.dumps(request).encode("utf-8")).decode("ascii")
    ssh = os.environ.get("FIND_SESSIONS_SSH") or "ssh"
    args = [ssh, "-o", "BatchMode=yes", "-o", "ConnectTimeout=%d" % SSH_CONNECT_SECONDS,
            address, "python3", "-", "--b64", payload]
    with open(os.path.abspath(__file__), "rb") as source:
        script = source.read()
    try:
        done = subprocess.run(args, input=script, capture_output=True,
                              timeout=timeout + SSH_CONNECT_SECONDS + 5)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "no answer from " + address}
    except OSError as error:
        return {"ok": False, "error": str(error)}
    if done.returncode != 0:
        detail = done.stderr.decode("utf-8", "replace").strip()
        return {"ok": False, "error": detail or "ssh exited %d" % done.returncode}
    try:
        return json.loads(done.stdout)
    except ValueError:
        return {"ok": False, "error": "unreadable answer from " + address}


def handle(request):
    if request["command"] == "tail":
        return tail_here(request["sessionId"], request["turns"])
    return search_here(request["terms"], request["any"], request["exclude"], request["limit"], request["timeout"])


def search_everywhere(request, use_peers):
    machines = [handle(request)] if not use_peers else None
    if machines is not None:
        return {"machines": machines}
    peers = load_peers()
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(peers) + 1) as pool:
        here = pool.submit(handle, request)
        asked = {machine: pool.submit(ask_peer, address, request, request["timeout"])
                 for machine, address in peers.items()}
        rows = [here.result()]
        for machine, future in asked.items():
            rows.append({"host": "", "sessions": [], **future.result(), "machine": machine})
    return {"machines": rows}


def main(argv):
    if argv[:1] == ["--b64"]:
        print(json.dumps(handle(json.loads(base64.b64decode(argv[1]))), ensure_ascii=False))
        return

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    search = commands.add_parser("search")
    search.add_argument("terms", nargs="+", metavar="TERM")
    search.add_argument("--all", action="store_true", help="also search the paired Macs")
    search.add_argument("--any", action="store_true", help="any term instead of every term")
    search.add_argument("--exclude", action="append", default=[], metavar="ID")
    search.add_argument("--limit", type=int, default=15)
    search.add_argument("--timeout", type=float, default=40)
    tail = commands.add_parser("tail")
    tail.add_argument("session_id", metavar="SESSION_ID")
    tail.add_argument("--machine", default="local", metavar="MACHINE_ID")
    tail.add_argument("--turns", type=int, default=3)
    args = parser.parse_args(argv)

    if args.command == "tail":
        request = {"command": "tail", "sessionId": args.session_id, "turns": args.turns}
        if args.machine == "local":
            result = handle(request)
        elif args.machine in load_peers():
            result = ask_peer(load_peers()[args.machine], request, 30)
        else:
            result = {"ok": False, "error": "unknown machine " + args.machine}
    else:
        exclude = args.exclude + [value for value in [os.environ.get("CLAUDE_CODE_SESSION_ID")] if value]
        request = {"command": "search", "terms": args.terms, "any": args.any, "exclude": exclude,
                   "limit": args.limit, "timeout": args.timeout}
        result = search_everywhere(request, args.all)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1:])
