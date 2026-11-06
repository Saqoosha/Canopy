---
name: find-session
description: Find which past Claude Code session a topic was discussed in, on this Mac and the paired Macs, and say where it stopped. Use when the user asks where something was discussed, which session it was, where they left off, or says they lost a session (「あの件どこ」「どのセッションだっけ」「どこまでやったっけ」, "where did we talk about X", "I lost the session about X"), or pastes a Slack or mail link and asks where it is being handled.
---

# Find a session

## Steps

1. **Turn the question into keywords.** Use both English and Japanese: prompts are often English and replies Japanese, so a Japanese word may exist only in the replies. Prefer rare words (`業務委託`, `collision`) over short or common ones (`r6`, `release`), which match too much.

2. **Search every Mac from the start.** Do not finish this Mac first.

   ```
   python3 "${CLAUDE_SKILL_DIR}/find_sessions.py" search --all TERM...
   ```

   Every term must appear in a session. Use `--any` for alternatives, such as the English and Japanese words for the same thing. Try a second search with other words before giving up.

3. **Read the likely candidates.** Use `machine` from the result row, which is `local` for this Mac.

   ```
   python3 "${CLAUDE_SKILL_DIR}/find_sessions.py" tail SESSION_ID --machine MACHINE
   ```

   Drop a session that only mentions the topic in passing. Drop one that was itself searching for this topic, such as `I lost the session about X`.

4. **Answer** with which Mac, which project, when, and where it stopped, best match first. Keep it short.

5. **If nothing fits, say so.** List near matches separately, and never present one as the answer. A row with `ok: false` means that Mac could not be searched, and `truncated: true` means its search did not finish. Say which Macs were not fully searched, by `host`: "could not reach studio" is not "not on studio". When `matched` is larger than the rows returned, more sessions matched, so narrow the words or raise `--limit` first.

## Opening a session

When the user asks to open a result, use its `sessionId`, `machine`, `title` and project folder name. A session on another Mac opens as a mirror pane. Canopy has to be open on this Mac.

```
python3 "${CLAUDE_SKILL_DIR}/../../bin/canopyctl" show SESSION_ID --machine MACHINE --title TITLE --project PROJECT
```

## Slack links

A link holds a message id (`p1793934540680779`) and sometimes `thread_ts=1793752895.604579`. Search them with `--any`, each in both forms: `p1793752895604579` is `1793752895.604579`.
