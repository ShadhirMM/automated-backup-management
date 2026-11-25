# Automated Backup Management: encrypted log backups

[![tests](https://github.com/ShadhirMM/automated-backup-management/actions/workflows/tests.yml/badge.svg)](https://github.com/ShadhirMM/automated-backup-management/actions/workflows/tests.yml)

A scheduled **PowerShell** workflow that copies designated log folders (local, network shares, or **cloud storage via rclone**) into an **encrypted restic repository**. Every run proves the backup is intact, applies retention, regularly test-restores the data, and reports **OK / WARNING / ALERT** with the likely root cause.

> Built as a portfolio project for an *IT Specialist (AI & Automation)* role whose job description lists *"an automated job that copies log folders from cloud storage into encrypted storage."*

| Requirement | How it is met |
|---|---|
| **Automated copying** | Daily scheduled task. Local/UNC folders are mirrored with robocopy (excludes, retries); cloud folders are copied with `rclone copy --checksum`. A staging copy freezes logs that are still being written |
| **Encrypted storage** | [restic](https://restic.net) repository: AES-256 + Poly1305, encrypted file names and contents, deduplicated snapshots. The restic binary's hash is pinned. No custom crypto |
| **Integrity verification** | SHA-256 manifest of every file, stored **inside** the snapshot → after backup, every file and size is checked against the snapshot listing → `restic check` with a data read-back (5% each run, 100% monthly) |
| **Failure notifications** | Webhook (Slack/Teams/any JSON, 3 attempts), JSON run report, daily log, optional Windows Event Log. Each failed step has a **root-cause hint**. A watchdog task alerts when no good backup was made in 26 h |
| **Retention** | keep 14 daily / 8 weekly / 12 monthly (configurable), then prune. **Runs only after the new backup is verified** |
| **Recovery testing** | Weekly automatic restore into a temp folder → every SHA-256 re-checked against the manifest → cleaned up. `Restore-LogBackup.ps1` for real restores, with the same check |

---

## How a run works

```
Task Scheduler (daily 02:00)                        Watchdog (every 6 h)
        |                                                  |
   lock -> copy sources to staging -> SHA-256 manifest       last good backup older than 26 h? -> ALERT
        -> restic backup (encrypted, tagged run:<id>)
        -> verify: manifest == snapshot listing, restic check (+ data read-back)
        -> retention: forget + prune          (skipped if verify failed)
        -> recovery test when due: restore -> re-hash -> compare -> delete
        -> staleness -> JSON report + log (+ Event Log) -> webhook if WARNING/ALERT
        -> delete the unencrypted staging copy -> exit code
```

## Sample output

Taken from the end-to-end demo (`scripts\Invoke-Demo.ps1`) running with real restic in CI:

```text
__DEMO_OUTPUT__
```

## Exit codes
| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | WARNING (e.g. optional source missing, incomplete snapshot, retention failed) |
| 2 | ALERT (required source missing, backup/verify/recovery test failed, stale) |
| 3 | Could not run (config, password, restic missing, another run in progress) |

## Quick start
```powershell
.\scripts\Install-Restic.ps1                 # official release, SHA-256 verified
notepad .\config\backup.config.json          # sources, repository, retention
.\scripts\Initialize-BackupRepository.ps1    # create the encrypted repository, store the password with DPAPI
.\src\Invoke-LogBackup.ps1 -ForceRestoreTest # first run
.\scripts\Register-BackupTask.ps1 -WhatIf    # then without -WhatIf
```
Full guide: [docs/INSTALL.md](docs/INSTALL.md). Restore: [docs/RECOVERY.md](docs/RECOVERY.md).

## Documentation
| Doc | For |
|---|---|
| [INSTALL](docs/INSTALL.md) | Set-up, config reference, scheduling |
| [OPERATIONS](docs/OPERATIONS.md) | Runbook: reading alerts, what to do for each failure, routine checks |
| [RECOVERY](docs/RECOVERY.md) | Step-by-step restore, damaged repository, lost password, restore drill record |
| [SECURITY](docs/SECURITY.md) | Encryption, password handling and key escrow, least privilege, unencrypted copies |
| [CHANGE_CONTROL](docs/CHANGE_CONTROL.md) | Test → deploy → verify → rollback |
| [TEST_PLAN](tests/TEST_PLAN.md) | What each test proves; manual go-live tests |
| [AI_BUILD_LOG](docs/AI_BUILD_LOG.md) | How AI was used and what the checks caught |

## Tests
**75 tests**: 59 unit tests plus 16 integration tests against **real restic**, run in GitHub Actions on **Windows PowerShell 5.1 and PowerShell 7**, with PSScriptAnalyzer at zero findings. The integration tests cover encryption at rest, tamper detection (a corrupted pack file), a file changed after the manifest (caught by both verify and the recovery test), wrong password, missing repository, missing source, and an exact retention policy using back-dated snapshots. A mutation check showed the tests catch deliberate bugs.

```powershell
.\tests\Invoke-Tests.ps1                 # analyzer + unit tests
.\tests\Invoke-Tests.ps1 -Integration    # + real restic (after Install-Restic.ps1)
```

## Repository layout
```
src/Invoke-LogBackup.ps1        entry point (Task Scheduler)
src/LogBackup/                  module: config, secrets, staging, manifest, restic wrapper, verify, retention, recovery test, notify
scripts/                        Install-Restic, Initialize-BackupRepository, Restore-LogBackup, Register/Unregister-BackupTask, Set-BackupWebhook, Invoke-Demo
config/backup.config.json       sources, repository, retention, thresholds
tests/                          Pester unit + integration tests, test plan
docs/                           INSTALL, OPERATIONS, RECOVERY, SECURITY, CHANGE_CONTROL, AI_BUILD_LOG
```

## Limitations (v1)
- Windows only (robocopy, DPAPI, Task Scheduler). restic itself is cross-platform; a macOS launchd version would need a Keychain-based secret store.
- Protection against ransomware deleting the backups needs append-only or object-locked storage; options are in SECURITY.md, not built in.
- Recovery tests restore the full latest snapshot. That is fine for log volumes; for very large repositories, set `sampleSize` and consider restoring a subset.

## License
MIT © Mushaff Shadhir
