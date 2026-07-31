---
name: NOW
description: Short-term layer — what is true this week, open threads, and claims. Read this first, before the durable memory index.
---

# NOW — current state

> **This is the only memory file that is *supposed* to go stale.** Everything else
> describes things that stay true. This one describes this week.

## Rules — keep this section, it travels with the file

**Does it belong here?** An entry belongs in NOW if, three weeks from now, it
would be **false** — not "less interesting", actually untrue.

- "Waiting on a push in three repos" → NOW. It can be wrong by tomorrow.
- "This service is non-profit by design" → never NOW. That is a durable note.

**Writing:** newest at the top, every entry dated `YYYY-MM-DD`, one line of state
plus, if needed, one line of "waiting on".

**A new entry does NOT invalidate an old one — you have to do that by hand.**
Adding a fresh truth beside a stale one leaves both, and the next reader takes
whichever sits higher or sounds more certain. When you close something, search
this file for the topic and strike **every** earlier mention in the same edit.

**Read status at the source, not from your own old entries.** "Is X done?" is
answered by the repo, the server, or the person. Not by compiling a list from this
file. This is a journal — a record of what was believed at a moment — not the
truth about the system.

**Weekly review.** Every entry gets exactly one of three fates. Nothing sits here
indefinitely.

- **Expires** — no longer true. Delete without ceremony.
- **Promotes** — turned out to be durable. Move it to a real note, delete it here.
- **Stays** — still open. Append `(carried: N×)`.

**Alarm:** an entry carried `3×`, or older than two weeks, is not "in progress".
It is dead or badly defined. Decide it — do not carry it a fourth time.

**What is NOT in here:** durable facts, decisions, architecture, anything that
outlives the quarter. Those get their own notes — see `MEMORY.md`. Credentials,
tokens, private keys, customer data, and regulated data do not belong in agent
memory at all.

**Claims** — coordination between concurrent sessions. Before starting anything
substantial (longer than half an hour, many files, pricing, policies, anything
you would hate to redo), append a claim: `🔨 [date, machine] area — what I'm
doing`. Update it with the result when you finish. **Read the claims at the start
of every session.** If someone is on your area, do something else — do not race.
This is not a lock; a shared file syncs with delay and a claim can arrive too
late. It is a signal that turns an expensive conflict into a cheap conversation.
Worktrees isolate code, but check whether your agent isolates *memory* too —
several share one memory directory across all worktrees of a repository, Claude
Code among them. Where that holds, nominate one memory writer or serialise edits
to this file and `MEMORY.md`.

---

## This week

<!-- One short paragraph: where the work actually stands. Rewrite, don't append. -->

---

## Open threads

<!-- Newest first. Use the status markers so a reader can scan:
     🔨 claimed / in progress   ⏸️ open, waiting   ✅ closed (keep briefly, then expire)
     ⚠️ needs a decision        🔄 handoff -->

### 🔨 [YYYY-MM-DD, machine] Claim — area — what I'm doing
One line on scope, and what other sessions should stay off. Update with the
result and where it landed.

### ⏸️ [YYYY-MM-DD] Thread title
What is open, and what specifically it is waiting on. If carried over, append
`(carried: 1×)`.

### ✅ [YYYY-MM-DD] Something that closed
What changed, verified how. Keep it briefly so the next reader sees it was
handled, then let it expire at review.

---

*Started: YYYY-MM-DD. Last review: YYYY-MM-DD. Next: YYYY-MM-DD.*
