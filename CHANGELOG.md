# Changelog

Notable user-visible changes are recorded here. This project follows semantic
versioning once stable releases begin; preview releases may still change file
formats and command behaviour.

## [Unreleased]

### Added

- `memory-doctor` hook mode, `-Hook` / `--hook`, for a `SessionStart` hook. It
  implies quiet, prints nothing when the result is healthy, and otherwise prints
  a compact plain-text report on stdout: the entries that need attention (at
  most 12; the rest are counted), the counts, one line per category, and the
  command for the full report with the exit code a manual run returns. It exits
  0 whatever it finds, because Claude Code adds a `SessionStart` hook's
  plain-text stdout to the agent's context only on exit 0 (Claude Code 2.1.283
  [hooks reference](https://code.claude.com/docs/en/hooks), read 2026-09-30).
  The previous `-Quiet` hook exited 1, so its diagnosis never reached the agent
  and dangling memory links went unnoticed for weeks. The PowerShell report is
  UTF-8 whatever the console code page. A PowerShell parameter that cannot be
  bound at all, such as a missing value, still fails before the script runs.
- `UNREADABLE`: a link whose target exists and is a directory, but whose content
  cannot be fully read — a permission error, a directory that cannot be entered,
  or a cloud placeholder that failed to download — has its own label, legend and
  count. It still fails the audit (exit 1 without the hook flag).

### Changed

- A read failure inside an existing link target was reported as `ORPHAN` ("the
  link target is missing") by the PowerShell doctor and as `INVALID` by the Bash
  doctor. Both now report `UNREADABLE`, so a healthy store with one file that
  failed to hydrate is no longer described as missing. The Bash doctor also
  reports a target directory it cannot enter as `UNREADABLE`, where it said
  `INVALID` ("target cannot be inspected").
- `memory-doctor.ps1` reports an unknown parameter as invalid input,
  `error: unknown argument: …`, with exit 2. It used to fail in PowerShell's
  parameter binding with exit 1 and a message on stderr only.
- The doctor's summary line includes an `unreadable` count.
- The README's `SessionStart` example uses `-Hook` / `--hook` in place of
  `-Quiet` / `--quiet`.

## [0.2.0-preview] - 2026-08-02

### Added

- `memory-doctor` now inspects a project's `.claude` settings and reports an
  `autoMemoryDirectory` that cannot work as written: a relative value the agent
  discards, a directory that does not exist, or an absolute path in a settings
  file that is itself inside a synced folder. It reports what would fail if
  applied; it still does not resolve settings precedence.
- `--project-dir` / `-ProjectDir` (repeatable, defaults to the current
  directory) and `--skip-settings-check` / `-SkipSettingsCheck`.
- Protocol and README guidance for the case where the project itself lives
  inside iCloud, Dropbox or OneDrive, where a per-machine link is the correct
  mechanism and `autoMemoryDirectory` is not.

### Changed

- `memory-doctor` exits 1 when a declared memory directory cannot work, so an
  existing pre-flight check will now catch this class. Use
  `--skip-settings-check` to keep the previous scope.

### Fixed

- `memory-doctor.sh` aborted with `unbound variable` instead of reporting an
  empty scan when the projects directory contained no projects, on Bash 3.2 —
  the version macOS still ships. A first run on a clean machine hit this.
- `link-memory.sh` hit the same empty-array trap while canonicalising a path of
  `/`, crashing instead of refusing the input.

## [0.1.0-preview] - 2026-07-31

### Added

- Three-rule protocol for stable memory, isolated code writers, and expiring
  short-term state.
- Native Claude Code `autoMemoryDirectory` onboarding with `/memory` and
  `/context` verification.
- Read-only legacy-layout doctors and dry-run-capable link migration tools for
  Bash on macOS/Linux and PowerShell 7.
- Portable `AGENTS.md` guidance with a Claude Code `@AGENTS.md` adapter.
- Templates for `NOW.md`, `MEMORY.md`, and durable topic notes.
- Work-claim example and lightweight contribution, security, and conduct files.

[Unreleased]: https://github.com/yakubzze/agent-ops/compare/v0.2.0-preview...HEAD
[0.2.0-preview]: https://github.com/yakubzze/agent-ops/compare/v0.1.0-preview...v0.2.0-preview
[0.1.0-preview]: https://github.com/yakubzze/agent-ops/releases/tag/v0.1.0-preview
