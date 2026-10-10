# Learnings: Peer names

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **No record means "not running", not "unnamed"; a failed directory listing must return nil, not `[:]`** — an empty result blanks every chip.
- **Two `~/.claude/sessions/*.json` records can share a `sessionId`** (a SIGKILLed CLI leaves its file) — newest `startedAt` wins, a record lacking it loses.
- **SSH remote sessions correctly show no peer name** — messaging is machine-local; do not route the read over SSH.
