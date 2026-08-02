# The agent-ops protocol

Three rules. Each is an **invariant** first and a mechanism second. The invariants
are about how agents and filesystems behave, not about one product — they hold
wherever an agent persists state per project, more than one session can touch a
tree, or notes get read back later. If you keep the invariants and replace every
file name in here, most of the value survives.

The mechanisms are concrete because vague advice is unusable, and the one adapter
that ships today is Claude Code: names like `CLAUDE.md`, `/memory` and `/context`
refer to its current behaviour, because that is what has been tested end to end.
Where your tool differs, [the last section](#applying-the-invariants-elsewhere)
has the three questions to ask of it.

Every rule below exists because something broke first. The failure is stated with
what it cost, because a rule without its scar gets discarded the first time it is
inconvenient.

*v0.1 preview: the rules are stable, the scripts and formats may still change.*

## Rule 1 — choose a stable memory location explicitly

**Invariant:** the active memory location is chosen by you, remains stable when
the code moves, and is verified from inside the running agent.

### The default failure

Claude Code stores auto memory under
`~/.claude/projects/<project>/memory/` by default. The project key is derived
from the Git repository (or from the project root outside Git). Renaming or
moving an independent clone can therefore select a new default directory. A
second independent clone has its own default path-keyed location. Nothing has
necessarily deleted the old notes; the new session simply is not reading them.

That looks like model amnesia, but the cause is address selection.

**What it cost.** Roughly six weeks of accumulated project memory, gone unnoticed,
because the symptom points at the model rather than the filesystem. The same trap
then hit a second project twice and a third three times — each time re-diagnosed
from scratch, because nobody connects "the agent forgot" to "I moved a folder".

Do not confuse a clone with a worktree:

- **Independent clone:** another repository location. Its default auto memory is
  separate.
- **Git worktree:** another checkout of the same repository. Claude Code shares
  auto memory across all worktrees and subdirectories in that repository.

The second property is useful for continuity but creates a separate concurrency
hazard covered by rule 2.

### Primary mechanism — native `autoMemoryDirectory`

For new setups on Claude Code 2.1.74 or newer, configure a stable directory
natively. Current Claude Code accepts `autoMemoryDirectory` from user, project,
local, policy, and `--settings` scopes. For one project, put this in
`.claude/settings.local.json` (personal) or `.claude/settings.json`
(team-shared after review):

```json
{
  "autoMemoryDirectory": "~/agent-memory/my-app"
}
```

The path must be absolute or start with `~/`. Project and local values are
honoured only after the workspace-trust dialog for that folder is accepted.
Review the setting before accepting: a cloned repository is asking permission
to redirect memory writes on your machine.

Keep personal configuration in `settings.local.json` and out of Git. A shared
`.claude/settings.json` can use a portable `~/agent-memory/<project>` path, but
the team should choose and document it deliberately. Another explicit option is
one external settings file per repository, selected at launch:

```bash
claude --settings /absolute/path/to/my-app.json
```

User settings at `~/.claude/settings.json` affect every project, so a
project-specific directory there is appropriate only for a dedicated profile.
Older Claude Code builds may support fewer scopes; verify the installed version
and current official documentation.

Auto memory is enabled by default from Claude Code 2.1.59. It can be toggled in
`/memory`; an explicit `autoMemoryEnabled: false` or
`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` disables it.

### When the project itself lives inside the synced store

The advice above assumes the settings file stays on one machine. That assumption
breaks when the project directory is inside iCloud Drive, Dropbox, OneDrive or an
equivalent: `.claude/settings.local.json` is then a synced file like any other. A
correct absolute path written on one machine arrives on the second machine, where
it does not resolve, and the agent falls back to the path-derived layout and
writes memory locally. Nobody forgot a step; the fix propagated the fault.

`~/agent-memory/<project>` survives this, because `~` is resolved per machine. A
path *into* the synced store generally does not, because providers mount at
different places per platform — one vault is
`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/<name>` on macOS and
`~/iCloudDrive/iCloud~md~obsidian/<name>` on Windows. No single absolute string is
correct on both, and `~/` cannot bridge the difference either.

Consequences, in order:

1. Prefer a store that is **outside** the synced project, addressed as
   `~/agent-memory/<project>`. The rule 1 mechanism then works unchanged.
2. If memory must live inside the synced tree — because the notes are part of the
   synced material — use a **per-machine link** and leave `autoMemoryDirectory`
   unset. A link is per-machine by construction: it is keyed by a path that is
   already local, so each machine holds its own correct entry. This inverts the
   usual preference, and it is the one shape where it should be inverted.
3. Never write a machine-specific absolute path into any file that syncs. This is
   the general form, and it is worth stating separately because it also covers
   hooks, wrapper scripts and editor configuration living beside the project.

`memory-doctor` reports a declaration that violates this, along with a relative
value and a directory that does not exist. It reports what cannot work; it does
not claim to know which scope Claude Code actually applied.

### Verify the resolved state

Configuration text is not proof that the running session uses it. Inside the
session, run:

```text
/memory
/context
```

- `/memory` shows configured memory-file locations, the auto-memory toggle, and
  an option to open the auto-memory directory. Its list can include files that
  do not exist yet.
- `/context` proves what occupies the live context, including the instruction
  and memory files that actually loaded.

Open the directory from `/memory`, write a harmless test note if necessary, and
confirm the expected file changed. After moving a clone or changing launch
settings, repeat the check.

Changing `autoMemoryDirectory` chooses an address; it does not migrate the
contents of the directory that was active before the change. Before switching
an existing project, record the old path with `/memory`, stop its writers, back
up both locations, and copy the complete tree—including hidden and
non-Markdown files. If both locations contain entries, use the deliberate merge
procedure below. Restart Claude Code and keep the old copy until `/memory`,
`/context`, and a direct read/write prove the new location across sessions.

### Migration fallback — links

The `link-memory` scripts preserve the older
`~/.claude/projects/<project>/memory` layout by moving its contents to a stable
store and linking the old path to the store. They are for migration, older
Claude Code versions, and environments where native configuration cannot be
used. They are not the default for a new setup.

Always inspect and dry-run first:

```bash
# macOS / Linux
./scripts/memory-doctor.sh
./scripts/link-memory.sh --project <slug> --store ~/agent-memory --dry-run

# Windows
pwsh ./scripts/memory-doctor.ps1
pwsh ./scripts/link-memory.ps1 -Project <slug> -Store "$HOME\agent-memory" -DryRun
```

The doctor audits the legacy directory/link layout. It does not resolve
Claude Code's effective `autoMemoryDirectory`; after switching to the native
setting, an old real directory can be inactive even if the doctor labels it
`AT RISK`. Check `/memory` before acting.

On Windows, use the PowerShell linker. A Git Bash `ln -s` may copy instead of
linking in common configurations, which produces two plausible directories that
drift. The shell linker refuses Windows environments for that reason.

### The migration edge case that matters

Both the old memory directory and the chosen store may already contain files.
They are not necessarily copies. Replacing either side can hide or destroy notes
that exist only there.

**This is not hypothetical.** One project had four notes in the store and eighteen
entirely different ones in a local directory, with zero overlap. A blind copy in
either direction would have destroyed one set, and because both directories look
plausible, nobody would have noticed for weeks. That is why the linker refuses
rather than guesses.

When both sides contain data:

1. Stop all sessions that can write either directory.
2. Make a separate backup of both sides.
3. Compare contents, including files other than Markdown.
4. Choose a master, copy unique files, and reconcile conflicting files by
   meaning rather than timestamp alone.
5. Merge `MEMORY.md` as a concise index, not by blindly concatenating it.
6. Run the migration again and keep its timestamped backup.
7. Verify through `/memory`, `/context`, and a direct file read/write.

The linker refuses detected content on both sides rather than choosing for you.
A dry run is a preview, not a backup.

The linkers also fail closed when either tree contains a nested symbolic link or
junction. Moving a relative link can silently change its target even when its
link text is preserved. Inspect and materialise the intended content, or design
an explicit external reference, before retrying the migration.

### Store and privacy boundary

Use a separate directory per unrelated project. Local storage is the simplest
default. Sync and version control can be useful, but they widen who and what can
retain the data.

Memory can contain internal paths, architecture, names, URLs, issue details,
customer context, or fragments of command output. It must not contain passwords,
API tokens, private keys, recovery codes, or regulated data. A private Git
repository still preserves deleted text in history and clones. A cloud or sync
provider may create server-side versions, conflict copies, local caches, and
backups. Confirm repository visibility, access control, retention, encryption,
and organisational policy before opting in.

Cloud placeholders are another availability failure: a file can appear in a
directory listing while its bytes are not present locally. Pin the store for
offline use and investigate conflict copies such as `MEMORY 2.md` immediately.

## Rule 2 — one working tree, one writer

**Invariant:** at any moment, exactly one session is authoritative for a given
working tree. Isolation of code does not imply isolation of memory.

### Why shared-tree concurrency fails

Two agent sessions do more than edit files. Each reads state, reasons for a
while, and acts on a snapshot that may now be false. On a shared tree:

- `git status`, tests, and type-check results expire as another writer changes
  files.
- `git add -A` can capture the other session's unfinished work.
- A commit message describes one intent while the commit includes two.
- If push triggers deployment, the combined blast radius reaches production.

**Measured both ways.** Without coordination, two sessions independently produced
the same work twice — a whole afternoon spent building something that already
existed. With a written claim and a rule about who commits what: three sessions,
one repository, one day, zero lost work — and one session independently verified
another's commits and caught a real error in them. The claim is cheap; the
duplicate is not.

### Preferred mechanism — isolated worktrees

Give each concurrent code-writing session its own worktree and branch:

```bash
git worktree add -b feat/agent-b ../app-agent-b
```

The explicit `-b` creates `feat/agent-b`; the next argument is the new checkout
directory. An existing branch instead uses:

```bash
git worktree add ../app-agent-b feat/agent-b
```

Each worktree has separate checked-out files and dirty state. It is still the
same Git repository.

### The auto-memory exception

Claude Code shares one auto-memory directory across worktrees of the same
repository. Therefore two sessions in perfectly isolated code worktrees can
still overwrite or interleave updates to `MEMORY.md`, `NOW.md`, or a topic file.

Choose a policy deliberately:

- nominate one session as the memory writer while others send it durable facts;
- serialize memory updates at handoff points; or
- give sessions distinct `autoMemoryDirectory` values through separate launch
  settings, then reconcile them deliberately later.

The last option trades write isolation for fragmented recall. Do not use file
timestamps as the sole merge rule. If two sessions need the same shared memory
and write concurrently, a claim is not a filesystem lock.

### If sessions must share a working tree

- Commit by intent with explicit paths or `git add -p`; never use `git add -A`.
- Never push while another session has uncommitted work in that tree.
- Re-run status and verification immediately before committing.
- If another writer appears, stop and let the owner finish rather than racing.
- Have each session commit only files it owns.

### Coordination claims

A claim is a short entry written before substantial work. It identifies the
area, paths, session/machine, and intended result. It is a signal that turns a
surprise conflict into a conversation; it is not mutual exclusion.

Write one for work longer than roughly half an hour, broad file changes,
migrations, pricing, policy, or anything costly to repeat. Read existing claims
at session start. Close the same claim when the work lands, and expire it during
the weekly review. See [examples/claim.md](examples/claim.md).

## Rule 3 — exactly one file is allowed to go stale

**Invariant:** durable knowledge and current status never share a file.

### Why mixed memory rots

Durable knowledge describes a constraint, decision, preference, or fact expected
to remain useful. Status describes now: an open thread, a handoff, a temporary
blocker, or work in progress.

When both accumulate in one file, old and new statements remain equally
plausible. Adding a correction does not remove the earlier claim, and a future
reader can choose the wrong one based on placement or confidence.

**What it cost.** A session handoff confidently reported an open task that had
been finished for days: three stale entries outweighed one fresh correction in
the same file. Nobody had written anything false. The file simply accumulated,
and the reader had no way to tell which line was current.

### The short-term layer

Use exactly one `NOW.md`. It is the only memory file expected to become stale,
and its expiry rules live in the file. Put an entry there if it is likely to be
false—not merely less interesting—in three weeks.

Write newest first with absolute dates. When something closes, search for the
topic and strike or delete every stale mention in the same edit. Read live status
from its source—the repository, service, issue tracker, or person—not by
compiling old notes.

During weekly review, every entry has one fate:

- **Expires:** no longer true; remove it.
- **Promotes:** proved durable; move it to a topic note and remove it from NOW.
- **Stays:** remains open; increment its carry counter.

An entry carried three times or older than two weeks needs a decision. It is
dead, blocked, or insufficiently defined; it does not get a fourth automatic
carry.

### The durable layer

Use `MEMORY.md` as a small index and one topic per note. The index should contain
only links to files that exist and short hooks that let a reader decide
relevance without opening everything. Use ordinary Markdown links for maximum
portability. If a project deliberately adopts `[[wikilinks]]`, document that as
a project convention and verify the chosen tools resolve them; they are not a
portable default.

Claude Code loads the first **200 lines or 25 KB of `MEMORY.md`, whichever comes
first**, at the start of each session. Content beyond either boundary is not
startup context. This limit applies to `MEMORY.md`, not topic files; Claude can
read those on demand. Therefore `MEMORY.md` is an index, never the place for full
notes or current status.

A durable note should contain:

- a stable filename and matching `name` field;
- a one-line description that supports relevance decisions;
- the fact or constraint;
- why it exists; and
- how it changes future action.

Do not copy facts already recoverable from code or Git history. Memory is for
what the repository cannot tell the next session cheaply.

## Where project instructions live

Keep shared, tool-neutral project guidance in one source such as `AGENTS.md`.
The format is supported by multiple agent tools, but support can be native,
configurable, or absent, and precedence differs. Verify the current behaviour of
each tool you use.

Claude Code reads `CLAUDE.md`; it does **not** natively load `AGENTS.md`. Its
adapter should use the documented import syntax:

```md
@AGENTS.md
```

That makes Claude Code load the shared instructions without maintaining a
second copy. A symlink can also work, but the import is more portable on Windows.
Use `/memory` to browse or edit configured files. Run `/context` to confirm that
the imported instructions actually loaded into the session.

Instructions contain invariants and pointers, not volatile status. Put anything
that can become false soon in `NOW.md`. Tool-specific rules may follow the import
in `CLAUDE.md`, but shared guidance stays in the one canonical file.

## Applying the invariants elsewhere

Before adapting this protocol to another coding agent, answer:

| Question | What to verify |
|---|---|
| Where is memory stored? | Is the location stable across moves, clones, machines, and worktrees? |
| What loads at startup? | Which files are native, configurable, imported, or ignored? |
| What is shared? | Can sessions write the same checkout, memory, cache, or external system? |
| What becomes stale? | Is current status separated from durable knowledge and reviewed? |
| How is active state proven? | Is there a runtime command comparable to `/memory` or `/context`? |

Translate only after observing the actual behaviour. Similar filenames are not a
compatibility guarantee.

## Official Claude Code references

- [Memory, CLAUDE.md imports, auto-memory location, and loading limits](https://code.claude.com/docs/en/memory)
- [Configuration diagnostics with `/memory` and `/context`](https://code.claude.com/docs/en/debug-your-config)
- [CLI reference for `--settings`](https://code.claude.com/docs/en/cli-usage)
