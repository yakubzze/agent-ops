# Security

`agent-ops` reads, moves, copies, backs up, and links local agent-memory
directories. A bug can expose notes to the wrong project or make the active copy
hard to find, even when no file is intentionally deleted.

## Report a vulnerability privately

Please use GitHub's private vulnerability-reporting flow for this repository:

<https://github.com/yakubzze/agent-ops/security/advisories/new>

If that flow is unavailable, open a public issue containing **no exploit,
private path, secret, or sensitive sample data**, or email
[`hello@gtlr.studio`](mailto:hello@gtlr.studio). Do not publish a working
destructive case before a fix is available.

Include the operating system, shell or PowerShell version, exact command with
sensitive paths replaced, expected result, observed result, and whether the
timestamped backup exists. A minimal synthetic directory tree is ideal.

Only the latest code on the default branch is supported during the v0.1 preview.
There is no guaranteed response SLA, but reports that can cause data loss,
cross-project disclosure, or command execution are the priority.

## User safety boundary

- Run the linker in dry-run mode before migrating real memory.
- Stop sessions that can write the source or destination during migration.
- Back up both sides before manually resolving a two-sided conflict.
- Keep the timestamped backup until `/memory`, `/context`, and direct inspection
  confirm the active directory and its contents.
- Treat memory as sensitive project data. Never store credentials, tokens,
  private keys, recovery codes, customer data, or regulated data in it.
- A private Git repository preserves removed material in history and clones.
  Cloud/sync stores may retain versions and conflict copies. Review visibility,
  access, encryption, retention, and organisational policy before use.
- Do not run migration scripts obtained from an untrusted fork without reviewing
  them.

The project cannot protect data after you place it in a third-party store or
grant another process access to the memory directory.
