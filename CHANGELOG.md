# Changelog

Notable user-visible changes are recorded here. This project follows semantic
versioning once stable releases begin; preview releases may still change file
formats and command behaviour.

## [Unreleased]

### Changed

- Nothing yet.

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
