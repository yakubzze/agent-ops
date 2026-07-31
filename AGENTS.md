# AGENTS.md

Guidance for agents working on `agent-ops`.

## What this project is

This repository contains a small continuity protocol and cross-platform migration
tools. The three invariants are tool-neutral; the adapter that ships today is
Claude Code. State that asymmetry plainly in both directions — never imply
universal support, and never describe the invariants as if they were properties
of one product.

Its safety claims matter more than convenience: never hide, overwrite, or delete
a user's existing memory to complete a link.

Every rule in the documentation is paired with the failure that forced it, and
what that failure cost. Do not sand those down into abstractions; they are what
makes the rules survive contact with someone who finds them inconvenient.

`PROTOCOL.md` is the canonical description of the invariants. Keep `README.md`
focused on onboarding and link to the protocol for full reasoning.

## Before editing

- Inspect `git status`; unfinished user work may already be present.
- Keep Bash and PowerShell behavior aligned.
- Treat every filesystem path and every existing directory entry as user data.
- Do not broaden compatibility claims without a tested adapter or an official
  source.

## Verification

Run the suites relevant to a change:

```bash
bash tests/bash/run-tests.sh
pwsh -NoProfile -File tests/powershell/run-tests.ps1
```

Also parse scripts before finishing:

```bash
bash -n scripts/memory-doctor.sh scripts/link-memory.sh tests/bash/run-tests.sh
```

```powershell
$errors = $null
[void] [System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path 'scripts/link-memory.ps1'),
  [ref] $null,
  [ref] $errors
)
if ($errors) { $errors; exit 1 }
```

## Safety contract for linkers

- Dry-run performs no filesystem mutations.
- Existing content on both sides always causes refusal; file extensions do not
  matter.
- Nested links inside either memory tree are refused; moving a relative link can
  silently change its target.
- Source and destination must be distinct, non-nested, canonical paths.
- Once the source moves to a backup, every later failure restores it.
- Backup and empty-destination holds live below atomically reserved containers;
  never move user data to a merely "currently unused" path.
- Rollback preserves a destination that no longer matches transaction-owned
  content instead of deleting a concurrent write.
- A successful idempotent run verifies that the link target exists and is a
  directory.
- Never turn a read or permission error into an "empty" result.

Tests must cover any change to one of these guarantees.

## Documentation

- Claude Code reads `CLAUDE.md`, which imports this file with `@AGENTS.md`.
- Native `autoMemoryDirectory` is the preferred Claude Code setup. The linkers
  are migration and legacy fallbacks.
- Worktrees isolate code, not Claude Code auto memory by default.
- Use absolute dates and version-qualified compatibility statements.

## Scope

Do not add a framework, package manager, telemetry, or network dependency. The
project should remain inspectable as Markdown plus native shell scripts.
