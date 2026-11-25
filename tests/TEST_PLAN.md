# Test plan

## Automated

`.\tests\Invoke-Tests.ps1 [-Integration]` runs PSScriptAnalyzer (must be 0 findings) and then Pester 5+.
CI (GitHub Actions, `windows-latest`) runs everything twice: under **Windows PowerShell 5.1** and under **PowerShell 7**. It uses the **real restic 0.20.0**, downloaded and hash-verified by `Install-Restic.ps1`, and then runs the end-to-end demo. Latest results: `tests/TEST_RESULTS.md`.

### Unit tests: 59, no restic needed

| Area | What is proven |
|---|---|
| Config | Example config loads; relative paths, `%ENV%` and repository URLs resolve correctly; defaults are filled in; 8 kinds of invalid config are rejected with clear messages |
| Helpers | Windows argument quoting (spaces, quotes, trailing backslash, empty); Windows → restic snapshot paths; NDJSON parsing |
| Staging | robocopy copy with excludes; deletions mirrored; missing required source → ALERT, optional → WARNING, and stale staged data removed; too few files → WARNING; rclone success and failure (with fake rclone) and remote-specific hint |
| Manifest | SHA-256 of every staged file, relative paths, manifest excludes itself |
| Manifest vs snapshot | Detects missing, resized and unexpected files; ignores paths outside staging |
| Status and hints | Worst-of status; exit codes; root-cause hints for wrong password, missing repository (new and old restic messages), lock, damaged data, disk full, incomplete snapshot; due-date maths with string and DateTime inputs; retention arguments |
| Lock and state | Second run blocked; stale lock taken over; atomic state save |
| Secrets | `RESTIC_PASSWORD` takes priority; DPAPI file round trip; the file does **not** contain the password; webhook URL from environment variable |
| restic wrapper | With a fake restic: password and repository reach the **child process only** (not the argument list, not this session's environment); exit code and stderr captured; a missing binary gets an install hint |
| Notifications | Readable text with hints for failed steps only; JSON payload; 3 attempts then `failed` without throwing; skipped when not configured |
| Orchestration | StaleCheck OK/ALERT; missing password → exit 3 with hint plus JSON report; lock held → exit 3 and the other run's lock left alone; invalid config → exit 3; restic failure → ALERT, hint, webhook sent, lock released, staging deleted, no "success" recorded; OK run → no webhook; daily log written |

### Integration tests: 16, real restic, temp folders

| Test | What is proven |
|---|---|
| Happy path | Every step OK; exit 0 |
| Encryption | No log text can be found in any repository file |
| Snapshot | Tags `logbackup`, `run:<id>`, host; all 8 files verified against the manifest; recovery test checked 8 files |
| State | Last success, restore test and snapshot recorded; JSON report; staging and lock removed |
| Incremental | Second run picks up a changed log; recovery test skipped when not due; 2 snapshots |
| RestoreTest mode | Latest snapshot restored and every SHA-256 matches |
| Verify mode | Full data read passes |
| Restore script | `Restore-LogBackup.ps1 -Source` restores only that source; hashes equal the originals |
| StaleCheck | OK right after a good backup |
| Missing source | ALERT, but the other source is still backed up and verified |
| Wrong password | ALERT with the password hint |
| Missing repository | ALERT with the repository hint; the repository is **not** auto-created |
| Tampering | Corrupting a pack file → `-Mode Verify` ALERT |
| Changed after manifest | A file changed between manifest and backup → verify ALERT (size differs) and recovery test ALERT (hash mismatch) |
| Retention safety | When verify fails, retention does **not** run and the older good snapshot survives |
| Retention policy | Snapshots dated 15 Jan, 15 Feb, 10–13 Mar with daily 3 + monthly 2 → exactly 15 Feb, 11, 12, 13 Mar kept; 2 removed; `restic check` clean after prune |

### Mutation check (done during the build)
Three deliberate bugs, each caught by the unit tests and then reverted:

| Mutation | Tests that failed |
|---|---|
| Removed the size comparison in manifest vs snapshot | 1 |
| Inverted the worst-of status logic | 4 |
| Kept stale staged data when a source disappears | 1 |

## Manual (on the target machine, before go-live)

| ID | Test | Pass when |
|---|---|---|
| M1 | `Install-Restic.ps1` | "SHA-256 matches SHA256SUMS and the pinned hash" |
| M2 | `Initialize-BackupRepository.ps1` as the task account | Repository created; `secrets\repo-password.xml` exists; password stored in the password manager |
| M3 | `Invoke-LogBackup.ps1 -ForceRestoreTest` | All steps OK |
| M4 | `Register-BackupTask.ps1 -WhatIf`, then for real; `Start-ScheduledTask` | `LastTaskResult` 0 |
| M5 | Unplug the backup disk; run | ALERT "Repository not found" received in the alert channel |
| M6 | Break the Slack webhook; run with a missing source | ALERT still logged; `notification: failed` in the report |
| M7 | Disable the Daily task for > 26 h | Watchdog ALERT |
| M8 | Restore drill on another PC with the escrowed password (RECOVERY.md) | All hashes match |
| M9 | `Unregister-BackupTask.ps1` | Tasks gone; repository untouched |
