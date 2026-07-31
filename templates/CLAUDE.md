@AGENTS.md

<!--
  The Claude Code adapter.

  Claude Code reads CLAUDE.md and does not read AGENTS.md natively. `@AGENTS.md`
  above is Claude Code's import syntax, not a Markdown link: a link is
  navigational and loads nothing, while the import pulls the shared file into
  context at session start. Keep it as the first line.

  A symlink works too, but on Windows it needs Administrator rights or Developer
  Mode, so the import is the portable default.

  Everything below is for guidance that is genuinely Claude Code-specific.
  Shared guidance belongs in AGENTS.md — two copies drift, and the next session
  cannot tell which one is stale.
-->

## Claude Code

**Memory location.** Auto memory defaults to `~/.claude/projects/<project>/memory/`,
where the project key is derived from the Git repository — so every worktree and
subdirectory of one repository shares it, and an independent clone gets its own.
Set `autoMemoryDirectory` in `.claude/settings.local.json` (personal) or
`.claude/settings.json` (team-shared) to pin it somewhere stable. The value must
be absolute or start with `~/`, and project-scoped settings apply only after you
accept the workspace-trust dialog for that folder.

**Verify what loaded.** `/memory` browses configured locations and opens the
memory directory, but it lists files that may not exist — it is not proof. Run
`/context` to see what is actually in the live context.

**Index size.** Only the first 200 lines or 25 KB of `MEMORY.md`, whichever comes
first, load at session start. Anything past that is silently dropped. Keep one
line per entry and move detail into topic files, which Claude reads on demand.

**Worktrees share memory.** Isolating code with `git worktree` does not isolate
memory: all worktrees of the same repository write one directory. If sessions run
concurrently, nominate one memory writer or serialise edits to `MEMORY.md` and the
topic notes.

[Add further Claude Code-specific rules here — for example, which paths should
always use plan mode.]
