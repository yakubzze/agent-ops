# Work claims — a worked example

A claim is a few lines written **before** you start, saying which area you are
taking. It is not a lock. It is a signal, and the signal is enough: it turns an
expensive merge conflict into a cheap "you take that, I'll take this".

Claims live at the top of `NOW.md`, newest first, next to everything else that is
allowed to go stale.

---

## While the work is running

```markdown
### 🔨 [2026-03-14, laptop] CLAIM — payments: refund flow + webhook retries
Area: `src/billing/**`, `src/api/webhooks/stripe.ts`, plus the `refunds` table
migration. **Don't touch these until this entry closes.** Everything else in the
repo is free.
Working on a separate worktree (`../app-refunds`, branch `feat/refunds`), so the
main tree stays clean. Commits local, nothing pushed yet.
```

Three things make it work: the **paths**, the sentence that says what is *not*
claimed, and where the work is happening. Another session can read this and know
in five seconds whether it is blocked.

## When it closes

Update the same entry rather than adding a new one below it — otherwise the file
grows two versions of the truth.

```markdown
### ✅ [2026-03-14, laptop] Payments: refund flow + webhook retries — DONE, 3 commits
Area released. `feat/refunds` merged, worktree removed.
Verified at the source, not assumed: 128/128 tests, type-check clean, a real
refund round-tripped against the Stripe test key.
One thing worth knowing: the webhook handler was retrying on 4xx, so a malformed
payload was replayed for an hour. Fixed in the second commit.
```

## When you find someone else's claim on your area

Do not race it. Pick different work, or say so and wait. The one thing that
reliably goes wrong is two sessions "just quickly" touching the same files.

If you genuinely have to work in parallel, take an isolated worktree instead of
sharing the tree:

```bash
git worktree add -b feat/agent-b ../app-agent-b
```

`-b` creates the new branch explicitly. If `feat/agent-b` already exists, use
`git worktree add ../app-agent-b feat/agent-b` instead.

The isolation is for checked-out code and dirty state. Claude Code shares auto
memory across worktrees of the same repository, so concurrent sessions can still
race on `NOW.md`, `MEMORY.md`, or a topic note. Nominate one memory writer or
serialize those updates; a claim is not a memory-file lock.

## A claim that is doing its job

```markdown
### 🔨 [2026-03-14, desktop] CLAIM — docs only
Rewriting `README.md` and `docs/**`. Not touching `src/`. If you need a doc
change, tell me rather than editing — I have the whole tree open in an editor
and will clobber you.
```

Short, specific about the boundary, and it names the failure it is preventing.

---

## The honest limitation

A claim written on a synced file can arrive after the other session already
started. It is a signal, not a lock — treat it as one. Two sessions on one
working tree remain hazardous even with perfect claims; the claim reduces how
often it hurts, it does not make it safe.

If the work is genuinely concurrent and genuinely overlapping, isolate. If it is
concurrent and separable, claim. If it is neither, take turns.
