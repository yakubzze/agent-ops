<!--
  Shared project guidance for coding agents.

  AGENTS.md is an open format read by a growing set of tools, natively or through
  configuration; support and precedence differ, so verify each tool you use. This
  file stays TOOL-NEUTRAL on purpose — anything true only of one agent belongs in
  that agent's adapter file, not here.

  For Claude Code, put templates/CLAUDE.md beside this file. It imports this one
  with @AGENTS.md and carries the Claude-specific parts.

  Replace bracketed text. Keep invariants and pointers here, never current status:
  anything likely to become false soon belongs in NOW.md.
-->

# Project guidance

These instructions are the shared source of truth for agents working in this
repository.

**Rule for this file:** invariants and pointers, not state. Counts, temporary
decisions, open work and handoffs live in `NOW.md` and expire there.

## What this project is

[What it does, who it serves, and the constraint that most shapes the work.]

## Session start

1. Read `NOW.md` for current state, open threads and claims. Treat it as a dated
   journal, then verify anything that matters at its source.
2. Read `MEMORY.md`, the durable-memory index, and open only the topic notes
   relevant to this task.
3. Check existing claims before taking a substantial area.

Durable memory for this project lives at:

```text
[absolute path or ~/path, kept outside this repository]
```

Confirm which instruction and memory files actually reached your context before
trusting them. Most agents offer a way to inspect this; if yours does not, read
the files directly rather than assuming they loaded.

Never put credentials, tokens, private keys, customer data or regulated data in
agent memory. If the store is synced or version-controlled, follow the project's
retention and access policy.

## Writing memory

- Short-lived facts, handoffs, blockers and claims go in `NOW.md`.
- Durable knowledge goes in one topic file per fact or tightly coupled concept.
- Keep `MEMORY.md` an index: a link, then one short relevance hook.
- Do not record what the next session can cheaply recover from the code or the
  repository history.
- Link only to files that exist, using ordinary Markdown links.

Some agents load only the first part of the memory index at session start, so keep
it short and let detail live in topic files that get read on demand.

## Concurrent sessions

Before substantial work — roughly longer than half an hour, many files, a
migration, pricing, policy, or anything costly to repeat — append a claim to
`NOW.md` naming the area, the paths, the session or machine, and the intended
result. Read existing claims first; if an area is owned, coordinate rather than
race.

One working tree has one writer. On a shared tree, stage explicit paths or use
`git add -p`; never `git add -A`. Do not push while another session has
uncommitted work. Re-check status and verification immediately before committing.

Prefer isolated worktrees for parallel code changes — but check whether your agent
also isolates *memory* per worktree. Several do not: code is isolated while the
memory directory is shared, so two sessions can still race on `MEMORY.md` or the
same note. Where that is the case, nominate one memory writer or serialise those
updates.

## Commands

```bash
[install]
[dev]
[test]
[build]
```

## Easy-to-miss conventions

[The two or three traps a competent newcomer would otherwise hit. Not a style
guide.]

## Destructive operations

[Name irreversible deletes, migrations, deployments or overwrites, and the safe
procedure for each.]

## Sources of live truth

[For each important status, name the command, service, tracker or person that is
authoritative. `NOW.md` is never the final authority.]

## Tool adapters

Keep shared guidance in this file. A tool-specific file should import or point
here and then contain only what is genuinely specific to that tool.

Do not maintain two copies of the same guidance. They start identical, one gets
updated, and the next agent reads whichever its tool prefers — with no way to tell
it has the stale one. That is the same failure as mixing status into durable
notes, wearing a different hat.
