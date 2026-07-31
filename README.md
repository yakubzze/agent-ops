# agent-ops

[![CI Status](https://github.com/yakubzze/agent-ops/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/yakubzze/agent-ops/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/OS-Linux%20%7C%20macOS%20%7C%20Windows-708090.svg)](#)

`// durable context for real agent work`

Three things break when you run AI coding agents on real projects, in this order:

1. **Your agent's memory quietly stops persisting.** Not with an error — it just
   starts reading somewhere else.
2. **Two agents on one checkout commingle their work.** One commit sweeps up the
   other's half-finished edits.
3. **Your notes rot.** A file that was true when written is wrong an hour later,
   and the agent reading it can't tell.

Every rule here exists because one of those happened first. The failure is
written next to the rule, with what it cost.

> **v0.1 preview.** The rules are stable; the scripts and file formats may still
> change before v1. Preview a dry run before migrating real memory, and keep the
> backup until you have verified the result.

## What each failure cost

**Memory that stops persisting.** Agents key per-project state by where the
project lives. Move the repo, clone it somewhere else, rename a parent folder —
the key changes, the agent finds nothing, and starts fresh. Nothing warns you.
That burned roughly six weeks of accumulated project memory before anyone noticed,
then hit a second project twice and a third three times, because the symptom
("the agent forgot") looks like a model problem rather than a filesystem one.

There is a sharper edge on the way out. When you finally move memory to a stable
home, both sides may already hold notes — and they may not be the same notes. One
project had four on one side and eighteen entirely different ones on the other. A
blind copy would have destroyed the eighteen. That is why `link-memory` refuses to
run when both sides have content.

**Two agents, one checkout.** Their edits interleave. `git status` changes between
one agent's own consecutive tool calls, so anything it reasoned about a moment ago
may already be false. `git add -A` — the natural thing for an agent to reach for —
sweeps the other session's half-finished work into your commit. If push deploys,
that ships.

Measured the other way too: three sessions, one repo, one day, zero lost work, and
one session independently verified another's commits and caught a real error in
them. The difference was a written claim and a rule about who commits what.

**Notes that rot.** A fresh entry gets appended next to a stale one. Both are
dated, both are confident, neither is marked wrong. The agent reads whichever sits
higher or sounds more certain — and reports it as fact. One handoff confidently
described an open task that had been finished for days, because three stale
entries outweighed one fresh correction in the same file.

## The three rules

1. **Choose your memory location explicitly.** It must not be derived from where
   your code happens to sit.
2. **One working tree has one writer.**
3. **Exactly one file is allowed to go stale, and it carries its own expiry
   rules.**

[PROTOCOL.md](PROTOCOL.md) is the full specification: the reasoning, the edge
cases, and the concurrency model. This README gets you running.

## What is universal, and what ships today

The three rules are about how agents and filesystems behave, not about one
product. They apply wherever an agent persists state per project, more than one
session can touch a tree, or notes are read back later.

The **tooling** currently implements one adapter: Claude Code. That is what the
scripts audit and what the templates name, because it is what has been tested
end to end. Everything else here — the rules, `NOW.md`, the note format, the claim
protocol — is plain Markdown and transfers directly.

If you use another agent, [PROTOCOL.md](PROTOCOL.md#applying-the-invariants-elsewhere)
has the questions to ask of your tool, and both scripts take a
`--projects-dir` / `-ProjectsDir` argument so they can audit any equivalent layout.
Adapters for other tools are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Start here

Clone it and read before you run anything. Nothing installs globally; the scripts
run from the checkout and the templates are yours to copy.

```bash
git clone https://github.com/yakubzze/agent-ops.git
cd agent-ops
```

Audit what you have. The doctor is read-only:

```bash
# macOS / Linux
./scripts/memory-doctor.sh

# Windows
pwsh ./scripts/memory-doctor.ps1
```

It reports, per project, whether memory sits somewhere stable or at a path that
will orphan itself the next time the code moves. It exits non-zero when anything
needs attention, so it works as a pre-flight check. Pass `-StableRoot` (or
`--stable-root`) to have it verify that links actually land inside the store you
chose, rather than just that they resolve.

### Give Claude Code a stable memory directory

Claude Code can be told where to keep memory, which is cleaner than any
filesystem surgery. Put this in the project's `.claude/settings.local.json`
(personal) or `.claude/settings.json` (team-shared, after review):

```json
{
  "autoMemoryDirectory": "~/agent-memory/my-app"
}
```

The value must be absolute or begin with `~/`. Project and local settings take
effect only after you accept Claude Code's workspace-trust dialog for that folder.
Inspect the path before accepting — the gate exists because a cloned repository
can otherwise redirect where memory gets written.

The same JSON is in [`examples/claude-settings.json`](examples/claude-settings.json):

```bash
cd /path/to/my-app
mkdir -p .claude
cp /path/to/agent-ops/examples/claude-settings.json .claude/settings.local.json
```

You can also keep one settings file per repository outside the repository and
start with `claude --settings /absolute/path/to/my-app.json`. User settings at
`~/.claude/settings.json` apply to every project, so do not put a project-specific
directory there unless that profile serves exactly one project.

### Verify what actually loaded

Inside Claude Code:

```text
/memory
/context
```

`/memory` browses configured locations and opens the memory directory — but it
lists files that may not exist, so it is not proof that anything loaded.
`/context` shows what is actually in the live context. Check there.

Claude loads only the first **200 lines or 25 KB of `MEMORY.md`**, whichever comes
first. Keep it a concise index and let detail live in topic files it reads on
demand.

## Moving existing memory safely

Pointing at a new directory selects a new location. **It does not move what is
already in the old one.** For an existing project:

1. Record the current directory with `/memory` before changing anything.
2. Stop every session that could write either location.
3. Back up both. If the new location already has entries, compare and merge them
   deliberately — never copy one side over the other.
4. Copy the complete old tree, including hidden and non-Markdown files.
5. Apply the setting, restart, and verify with `/memory`, `/context` and a
   harmless read and write.
6. Keep the old copy until the new one has survived normal use and a restart.

### Link fallback

The link scripts are for when a native setting is unavailable, or when you must
preserve a layout that already expects `~/.claude/projects/<project>/memory`.

Stop sessions that can write either path, then preview:

```bash
# macOS / Linux
./scripts/link-memory.sh --project <slug> --store ~/agent-memory --dry-run

# Windows
pwsh ./scripts/link-memory.ps1 -Project <slug> -Store "$HOME\agent-memory" -DryRun
```

If the preview is right, repeat without the dry-run flag. The linker refuses to
guess when both sides hold entries, and keeps a timestamped backup — hold onto it
until `/memory`, `/context` and a direct file check all agree.

Both linkers also refuse nested links inside either memory tree. A relative link
can resolve to a different target once the tree moves, so replace it with
deliberate, self-contained content first.

> **Windows: link with PowerShell.** Git Bash can implement `ln -s` as a copy,
> which leaves two directories silently drifting apart — exactly the failure this
> repo exists to prevent. The shell linker detects that and refuses. The doctor
> is read-only and runs fine there.

The doctor reads the on-disk layout; it does not resolve settings. A directory it
calls `AT RISK` may be an inactive old location after you have configured a native
one — confirm with `/memory` before migrating anything.

## Worktrees: code is isolated, memory is not

A Git worktree is another checkout of the **same repository**, and Claude Code
shares one memory directory across a repository's worktrees and subdirectories.
Worktrees isolate branches and dirty files. They do not stop two sessions racing
on `MEMORY.md` or the same topic note.

An independent `git clone` is a different location and gets its own memory. Point
two clones at one store only when sharing is intentional, and coordinate writes
when they run at the same time.

```bash
git worktree add -b feat/agent-b ../app-agent-b
```

Claims in `NOW.md` help sessions coordinate, but they are signals, not locks. See
[the concurrency rule](PROTOCOL.md#rule-2--one-working-tree-one-writer) and the
[worked claim](examples/claim.md).

## Files in this repository

| Path | Purpose |
|---|---|
| `PROTOCOL.md` | The rules in full, with reasoning and edge cases |
| `templates/AGENTS.md` | Tool-neutral project guidance, in the open format |
| `templates/CLAUDE.md` | The Claude Code adapter: imports `@AGENTS.md`, adds only what is tool-specific |
| `templates/NOW.md` | Expiring short-term status and work claims |
| `templates/MEMORY.md` | Concise index for durable memory |
| `templates/memory-note.md` | One durable note = one fact |
| `scripts/memory-doctor.*` | Read-only audit of the on-disk memory layout |
| `scripts/link-memory.*` | Migration with dry run, conflict refusal and rollback |
| `examples/claim.md` | A worked coordination claim |
| `examples/claude-settings.json` | Minimal native memory-directory settings file |

`AGENTS.md` is an open format read by a growing set of tools, though support and
precedence differ by product. Claude Code does **not** read it natively, so the
included `CLAUDE.md` uses Claude Code's `@AGENTS.md` import — one source of
guidance, two tools, no second copy to drift.

## Compatibility

| Surface | Tested scope in this preview |
|---|---|
| Claude Code memory | Native memory-directory setting on current builds; verify yours with `claude --version` |
| Bash tooling | macOS and Linux; exercised in CI on GitHub-hosted macOS and Ubuntu runners |
| PowerShell tooling | PowerShell 7 on Windows, macOS and Linux; Windows uses a directory junction |
| Git Bash on Windows | Read-only doctor; the Bash linker refuses, so use the PowerShell one |
| Other coding agents | Rules and templates transfer; no storage adapter ships yet |

This describes what has been tested, not everything these files might happen to
work with.

## Choosing a store

`~/agent-memory/my-app` — local, per project — is the least surprising default and
the right answer for most people. You get rule 1's protection without depending on
anything else.

| Store | When it makes sense |
|---|---|
| Local directory | One machine. Simplest thing that works. |
| A private Git repo | You want history and diffs on your notes. |
| Cloud folder (OneDrive, Google Drive, iCloud, Dropbox) | You work from more than one machine. |
| Syncthing or similar | Same, without a provider in the middle. |

Nothing in the protocol changes between these — the store is a path.

**If you sync, two things will bite you.** Each machine needs its own link or
setting, because the path differs per machine; set one up, forget the other, and
that one silently writes somewhere local. And on-demand files — OneDrive Files
On-Demand, Google Drive streaming, iCloud Optimise Storage — leave placeholders
that look like real files in a listing but fail on read. An agent hits a cloud
error instead of the note, which surfaces as "permission denied" or an empty read.
Neither looks like "this was never downloaded". Pin the store to always-keep-local,
and watch for conflict copies like `MEMORY 2.md`.

### Before you sync anything

Memory can contain filenames, internal URLs, architecture notes, names, customer
context, and text pasted from tool output. **Never put credentials, tokens,
private keys or regulated data there.** Git preserves removed text in history;
sync providers keep additional copies and often retain deleted versions. Check the
provider, repository visibility, access controls, retention and your
organisation's policy first. [SECURITY.md](SECURITY.md) has the compact threat
model.

## What this is not

Not a framework, not a dependency, not a methodology to adopt wholesale. A set of
conventions that survived contact with real projects, plus the scripts that make
the first rule enforceable.

Take the parts that map to how you already work. The file layout matters least —
start from what each failure cost.

## Why this exists

I run several projects with agents doing real work in them — shipping code,
holding context across weeks, sometimes three sessions at once. Everything here
was learned the expensive way and is written down so you don't have to pay for it
twice.

Contributions welcome — start with [CONTRIBUTING.md](CONTRIBUTING.md), and follow
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

Built by [yakubzze](https://gtlr.studio). MIT.

## References

- [Claude Code: memory and the memory directory setting](https://code.claude.com/docs/en/memory)
- [Claude Code: debug configuration with `/memory` and `/context`](https://code.claude.com/docs/en/debug-your-config)
- [Claude Code CLI: `--settings`](https://code.claude.com/docs/en/cli-usage)
