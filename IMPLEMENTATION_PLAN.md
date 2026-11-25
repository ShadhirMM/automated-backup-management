# Automated Backup Management: implementation plan

> **Status: v1.0.0 complete.** 59 unit tests + 16 integration tests against real restic pass in CI on Windows PowerShell 5.1 and PowerShell 7. **Still to do on the target machine:** manual tests M1–M9 (real task registration, a real cloud remote, a real webhook, a restore drill) with screenshots.

**Brief:** create a workflow to copy designated log folders into encrypted storage, with automated copying, integrity verification, failure notifications, and backup retention and recovery testing.

**Job description line:** *"an automated job that copies log folders from cloud storage into encrypted storage"*.

## Design decisions
| Decision | Why |
|---|---|
| **restic** repository as the encrypted storage | Audited, widely used, authenticated encryption (AES-256 + Poly1305); snapshots, dedupe, `check`, `forget/prune`, `restore` built in. No custom crypto |
| PowerShell 5.1-compatible orchestrator | Runs on any Windows machine without installing anything except restic; Task Scheduler; consistent with the other PowerShell tools |
| Staging copy + SHA-256 manifest inside the snapshot | Logs change while being written; staging freezes them, so the manifest and the snapshot describe the same bytes, and a restore can always prove integrity on its own |
| rclone for cloud sources | The job description's "from cloud storage"; `rclone copy --checksum` |
| DPAPI password file + key escrow | No plain-text secret on disk; but a lost password means lost data, so escrow is a documented step |
| Retention only after a verified backup | A failing new snapshot must never cause good old ones to be deleted |

## Phases
| # | Phase | Done |
|---|---|---|
| 1 | restic installer with hash pinning | ✅ |
| 2 | Config + validation | ✅ |
| 3 | Staging (robocopy / rclone) + manifest | ✅ |
| 4 | Backup + verify (manifest vs snapshot, `check`, read-data subset/full) | ✅ |
| 5 | Retention (forget + prune) | ✅ |
| 6 | Recovery test + restore script | ✅ |
| 7 | Notifications (webhook with retries, event log, JSON report, logs), staleness watchdog | ✅ |
| 8 | Scheduled tasks (+ pre-flight, -WhatIf, rollback) | ✅ (dry run only) |
| 9 | Tests (unit + real-restic integration), CI on 5.1 and 7, mutation check | ✅ |
| 10 | Docs | ✅ |
| 11 | Go-live checks M1–M9 | ⏳ target machine |

## Mapping to the job description
| Job description line | Where |
|---|---|
| "automated job that copies log folders from cloud storage into encrypted storage" | rclone/robocopy staging → restic repository; daily scheduled task |
| "Diagnose … build the evidence" / "fix failures at the root cause" | Every failure has a root-cause hint; run reports and logs |
| "Roll out security controls such as … encryption" | restic encryption, DPAPI secrets, key escrow |
| "Follow change control: confirm the scope, test, document and keep a tested rollback" | CHANGE_CONTROL.md, unregister script, retention dry-run rule |
| "Package each program with its configuration, installation steps and documentation, test it before deployment" | config, INSTALL.md, 75 tests in CI |
