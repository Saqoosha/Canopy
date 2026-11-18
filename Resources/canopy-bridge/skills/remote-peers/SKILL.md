---
name: remote-peers
description: Message a Claude session running on another Mac paired in Canopy. Use when the user asks to talk to, ask, hand something to, or coordinate with a session on another Mac (studio, another machine, a mirror pane), or when ListAgents does not show the session they mean because it runs elsewhere.
---

# Message a session on another Mac

`ListAgents` and `SendMessage` reach sessions on this Mac only. Canopy relays them to the Macs paired in Settings › Remote.

## Steps

1. **List the sessions on the paired Macs.**

   ```bash
   python3 "${CLAUDE_SKILL_DIR}/../../bin/canopyctl" peers
   ```

   Each row in `peers` has `machine`, `name`, `cwd`, `status` and `address`. `errors` names any Mac that did not answer.

2. **Send with SendMessage, using the row's `address` as `to`** (the whole `uds:/…` string). Pick the row by `name` and `machine`; ask the user when more than one fits.

3. **Replies arrive like any cross-session message.** The sender shows as `<name> on <machine>`, and its `from` is a local `uds:` address: copy it as `to` to answer.

A message to a session running in a different permission mode is held for its user's approval. The VS Code extension, and so a Canopy pane, does not show that approval, so the message expires unseen. If no answer comes back, say so instead of resending.
