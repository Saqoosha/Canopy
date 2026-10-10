# Learnings: Rate limits per account

Condensed from CLAUDE.md. Full original text: `git show 3b6a198:CLAUDE.md`.

- **A shim stores the account KEY, not the record** — look it up with `account(for:)` on every write so a `.host` fallback folds into the account a later session learns (`noteResolved`); holding the record duplicates accounts.
- **A predicate called from a view body must not create on miss** — `isWriting(to:)` compares keys; a lookup that appends mutates the `@Observable` registry mid-render.
- **Re-request usage when the account resolves, gated on `channelId`** — the first request (2 s after launch) usually beats the SSH read; without the gate a pre-launch resolve burns the throttle.
- **Lowercase the host, keep the user, in `user@host` keys** (`Key.normalizedHost`).
- **An empty `@ViewBuilder` child still gets `VStack` spacing** — emit nothing with the padding inside the `if`.
- **`studio` is a different account** and the test bed for account-scoped work.
