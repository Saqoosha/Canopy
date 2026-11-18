# Learnings: Cross-Mac peer messages

Measured on CLI 2.1.326 (2026-11-18). The relay is `PeerRelay`; the verbs are in `docs/CONTROL_PROTOCOL.md`.

## The CLI's peer wire

- Each session listens on `messagingSocketPath` from `~/.claude/sessions/<pid>.json` (`/tmp/cc-socks/<pid>.sock`, dir 0700). There is no handshake and no key: a send is one connection carrying one newline-terminated JSON line.
- The line: `{"msgV":1,"msg_id","type":"user","message":{"role":"user","content":"<cross-session-message from=\"uds:…\" from-name=\"…\" from-mode=\"bypass|prompting\">\n…\n</cross-session-message>"},"priority":"next","from":"uds:…"}`. The receiving Claude reads its reply address from the tag, the CLI from the top-level `from`; rewrite both.
- The receiver answers by connecting to `from`: replies, and `{"type":"control","action":"peer_message_status",…}` receipts. It accepts a `from` in its own socket directory whose name matches `^(\d+(-[0-9a-f]{8})?|[0-9a-f]{1,16})\.sock$`. That is why proxies are 16-hex names next to the session sockets. A proxy's name hashes the bundle id, machine and remote socket, so the reply to a message arrives from the same `uds:` address it was sent to, and copying `from` keeps the conversation going.
- A line from a non-CLI process is accepted. `SendMessage` takes `uds:<path>` as `to`.

## Holds

- `from-mode` has two classes: `bypass`, and `prompting` for every other mode (an `auto` session sends `prompting`). With `crossSessionInbound` unset, a message whose class differs from the receiver's (or has none while the receiver bypasses) is held for approval. The relay forwards the sender's `from-mode` untouched, so the same rule applies across Macs.
- The CLI reports a hold as `system/peer_message_hold` on stream-json, informational only: no host can approve through it. Only the TUI has the approval dialog ("Held message from another session"). The VS Code extension 2.1.326 does not handle that frame, so in it and in Canopy a held message expires unseen.

## Pairing

- Replies go back over `PeerControl`, so both Macs must hold each other's connection in Settings › Remote. `peer_deliver` refuses a sender with no entry in `canopy.mirrorPeers`; that is not an identity check, since any client holding the control password can name any paired Mac.
- A delivery failure on the far side is only logged on the sending Mac. The sending CLI already counted the send as done, so its Claude just never gets an answer.
- `MachineIdentity.stableId()` (IOPlatformUUID) is the key in the other Mac's `canopy.mirrorPeers`.

## Testing

- The mirror TCP port belongs to the Release daemon, so a cross-Mac round trip needs the new build installed on both Macs. A Debug daemon can test only the receiving half: call `peer_deliver` on its Unix socket with a paired Mac's id as `fromMachine` and a hand-written line (`from-mode` matching the target session, or it is held).
- First round trip: 3.26.0 on MBP and studio, both sessions `auto`. `canopyctl peers` listed studio's sessions, `SendMessage` reached studio's session, and its reply arrived here as "<name> on Studio".
- Every `peers` row is a live session doing real work; a `SendMessage` lands in it as the next user turn. Test against a throwaway session (a No folder session works).
