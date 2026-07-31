# Contributing

Thanks for helping context survive one more session.

This is a small v0.1-preview project. Focused fixes, reproduced edge cases, and
clearer documentation are more valuable than broad new machinery.

## Before changing something

- For a typo or contained bug, open a pull request directly.
- For a new rule, file format, or behaviour change, open an issue first so the
  invariant and failure case can be agreed before code grows around it.
- Do not include real memory stores, credentials, customer information, internal
  URLs, or private command output in issues, fixtures, or screenshots.

## Make the change

1. Fork and create a narrow branch.
2. Keep `PROTOCOL.md` canonical. The README should onboard and link to it, not
   repeat the complete protocol.
3. When documenting Claude Code behaviour, cite current official documentation
   and state the relevant minimum version.
4. Preserve dry-run, conflict refusal, backups, and rollback behaviour in any
   migration change.
5. Add or update tests for behaviour changes. Run the checks available for your
   platform and say exactly what you could not run.

The test runners have no package dependencies:

```bash
bash tests/bash/run-tests.sh
pwsh -NoProfile -File tests/powershell/run-tests.ps1
pwsh -NoProfile -File tests/repository/run-tests.ps1
```

The Bash linker cannot safely create links from Git Bash on Windows. Run its
integration suite on macOS/Linux or let the GitHub Actions matrix cover it.

## Pull request notes

Briefly include:

- the failure or confusion being fixed;
- the chosen behaviour and why;
- commands and platforms used to verify it; and
- any compatibility or migration consequence.

Small pull requests are easier to review and safer to reuse. By contributing,
you agree that your contribution is licensed under this repository's MIT
license and that you will follow the [Code of Conduct](CODE_OF_CONDUCT.md).
