# AI build log

Built with **Claude Code** (Claude Opus 5.5). The rule: **AI writes, tests decide.**

| Step | AI output | How it was checked |
|---|---|---|
| Design | restic for encryption, integrity, retention and restore, instead of custom crypto; PowerShell orchestration for Windows and Task Scheduler | Reviewed against the brief and the job description; restic's design documentation for the crypto claims |
| restic install | `Install-Restic.ps1` with SHA256SUMS check plus a pinned hash | The pinned hash was taken from the official release's SHA256SUMS. In CI the script downloaded, verified ("matches SHA256SUMS and the pinned hash") and ran restic 0.20.0 |
| Module | `LogBackup.psm1`: config, secrets, staging, manifest, restic wrapper, verify, retention, recovery test, notifications, orchestration | 59 unit tests (local, PS 5.1) + 16 integration tests with real restic (CI, PS 5.1 and 7) |
| Scripts | init/restore/register/unregister/webhook/demo | PSScriptAnalyzer 0 findings; integration test for the restore script; `-WhatIf` support |

## What the checks caught
- **Strict mode on config objects:** `Set-StrictMode` made the first config loader throw "property cannot be found" for optional sections, and that hid the real validation messages (8 failing unit tests). The loader was rewritten with safe property access (`Get-Prop`) and explicit defaults.
- **Sums of empty folders:** `Measure-Object` on an empty folder returns no `Sum` under strict mode. Replaced with explicit loops.
- **The password was plain text inside the module.** PSScriptAnalyzer flagged every `-Password [string]` parameter. Refactored so the password stays a `SecureString` until the moment restic starts, and is placed only in the child process environment. A unit test proves it is not in the argument list or in this session's environment.
- **Non-ASCII characters** (em dashes) in `.ps1` files: Windows PowerShell 5.1 reads UTF-8 without a BOM as ANSI. All PowerShell files are now ASCII-only.
- **CI found two problems that did not show up locally:** (1) with `$ErrorActionPreference = 'Stop'`, rclone's stderr output became a terminating error before the exit code could be read. The copy function now uses its own `Continue` preference and decides on exit codes. (2) PSScriptAnalyzer on PowerShell 7 flagged a test helper named `Node` (clashes with a built-in), so it was renamed.
- **Mutation check:** three deliberate bugs (no size check, inverted worst-of status, stale staged data kept) were each caught by 1–4 failing tests.

## Limits of the build environment
- restic could **not** be run on the build PC: downloading and running the binary locally was blocked by the build machine's safety policy. So every real-restic behaviour (encryption, verify, tampering, retention, restore) was proven **in GitHub Actions only**, on Windows PowerShell 5.1 and PowerShell 7. The sample output in the README is copied from that CI run.
- Not verified: rclone against a real cloud remote (only a fake rclone in tests); Task Scheduler registration for real (only `-WhatIf`); Windows Event Log writing (needs admin to create the source); a real Slack/Teams webhook (the payload is mocked in tests). These are manual tests M1–M9 in `tests/TEST_PLAN.md`.
