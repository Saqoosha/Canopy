---
name: move-session
description: Move this session, conversation included, to another folder on this Mac. Use when the user asks to move or continue the conversation in a project or folder, or agrees to it after a No folder session turned into work on a project.
---

# Move this session

## Steps

1. **Settle the folder.** If the user names a project, find its absolute path (`~/repos` and the like). If more than one folder fits, ask which one.

2. **Create a folder only when the user asks for one.**

3. **Ask for the move.**

   ```bash
   python3 "${CLAUDE_SKILL_DIR}/../../bin/canopyctl" move --session-id "${CLAUDE_SESSION_ID}" --path /absolute/path
   ```

4. **Tell the user and end the turn.** Say the session moves after this turn, once nothing else runs in it, and that a folder Claude Code has not trusted yet raises a confirmation only when it holds Claude Code config that came from outside. The confirmation shows on the screen of the Mac that runs the session and on any other Mac whose Canopy is showing it, and either can answer. Nothing moves while the turn runs, so do not keep working and do not check whether it moved.

If `canopyctl` reports an error, say so in plain words. A session in a worktree or on an SSH remote cannot move. A second request replaces one that has not started, and is refused while one is under way.
