# Test results

From GitHub Actions run on the v1.0.0 code (`windows-latest`).

## Windows PowerShell 5.1

- Pester 6.2.0 on PowerShell 5.1.26100.33822
- restic 0.20.0 compiled with go1.27.4 on windows/amd64
- PSScriptAnalyzer findings: 0
- **Tests Passed: 75, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0**

```
[+] first run is OK with every step passing 88ms
[+] stores the snapshot encrypted (no log text readable in the repository files) 34ms
[+] tags the snapshot with job and run id, and verified every file 743ms
[+] records state and a JSON report, and cleans up the unencrypted staging copy 23ms
[+] second run picks up new log lines and skips the restore test when not due 3.8s
[+] RestoreTest mode restores the latest snapshot and checks every hash 800ms
[+] Verify mode reads back all data 773ms
[+] Restore-LogBackup.ps1 restores one source and proves it intact 1.56s
[+] StaleCheck is OK right after a good backup 22ms
[+] missing required source: ALERT, the other source is still backed up, and retention does not delete the complete snapshot 10s
[+] wrong password: ALERT with the password hint, nothing deleted 3.73s
[+] repository unreachable: ALERT with the repository hint (never auto-initialised) 132ms
[+] tampered repository data is detected by verification 7.72s
[+] recovery test catches files that changed between manifest and backup 5.32s
[+] does not apply retention when verification fails 8.74s
[+] keeps exactly what the policy says (daily 3 + monthly 2) 10.8s
[+] loads the shipped example config and resolves paths against the project root 27ms
[+] leaves repository URLs alone and expands environment variables 7ms
[+] fills in defaults for optional sections 21ms
[+] rejects no sources 84ms
[+] rejects duplicate source names 7ms
[+] rejects unknown source type 7ms
[+] rejects bad rclone remote 6ms
[+] rejects retention keeping nothing 6ms
[+] rejects negative retention 4ms
[+] rejects missing repository 6ms
[+] rejects invalid JSON 45ms
[+] quotes process arguments: abc 9ms
[+] quotes process arguments: a b 2ms
[+] quotes process arguments: a"b 2ms
[+] quotes process arguments: C:\x y\ 2ms
[+] quotes process arguments:  2ms
[+] converts Windows paths to restic snapshot paths 9ms
[+] parses newline-delimited JSON and skips other lines 5ms
[+] copies a local folder with robocopy and honours excludes 29ms
[+] mirrors deletions (a log removed at the source is removed from staging) 40ms
[+] raises ALERT for a missing required source, WARNING for an optional one, and drops stale staged data 11ms
[+] warns when a source has fewer files than the minimum 14ms
[+] stages cloud folders with rclone and reports rclone failures with a hint 30ms
[+] writes a SHA-256 manifest of every staged file (but not of itself) 16ms
[+] passes when every file is present with the same size 4ms
[+] reports missing, resized and unexpected files 3ms
[+] ignores files outside the staging folder 2ms
[+] overall status is the worst step 7ms
[+] maps exit codes to OK 4ms
[+] maps exit codes to WARNING 2ms
[+] maps exit codes to ALERT 2ms
[+] gives a root-cause hint for wrong password 2ms
[+] gives a root-cause hint for missing repository 1ms
[+] gives a root-cause hint for old restic missing repo 1ms
[+] gives a root-cause hint for lock 1ms
[+] gives a root-cause hint for damaged data 1ms
[+] gives a root-cause hint for disk full 1ms
[+] gives a root-cause hint for incomplete snapshot 1ms
[+] works out when a task is due (string and DateTime inputs) 16ms
[+] builds retention arguments only for non-zero keeps 2ms
[+] blocks a second run and releases on exit 10ms
[+] takes over a stale lock 7ms
[+] saves and reloads state atomically 15ms
[+] prefers RESTIC_PASSWORD, else reads the DPAPI file, else explains what to do 105ms
[+] reads the webhook from the configured environment variable 5ms
[+] passes repository and password only through the child environment 24ms
[+] explains a missing restic binary 26ms
[+] formats a readable message with hints for failed steps only 7ms
[+] posts JSON with text, status and steps 119ms
[+] retries 3 times, then reports failure without throwing 55ms
[+] does nothing when no webhook is configured 3ms
[+] StaleCheck: ALERT when no backup was ever recorded 81ms
[+] StaleCheck: OK when recent, ALERT when older than the limit 93ms
[+] exit 3 with a hint when the password is missing, and writes a JSON report 61ms
[+] exit 3 when another run holds the lock, and leaves that lock alone 90ms
[+] exit 3 for an invalid config (no report, no crash) 66ms
[+] ALERT from restic is reported with the hint, and the webhook is called 222ms
[+] does not send a webhook for OK runs unless onSuccess is set 71ms
[+] writes a daily log file 86ms
```

## PowerShell 7

- Pester 6.2.0 on PowerShell 7.6.10
- restic 0.20.0 compiled with go1.27.4 on windows/amd64
- PSScriptAnalyzer findings: 0
- **Tests Passed: 75, Failed: 0, Skipped: 0, Inconclusive: 0, NotRun: 0**

```
[+] first run is OK with every step passing 86ms
[+] stores the snapshot encrypted (no log text readable in the repository files) 38ms
[+] tags the snapshot with job and run id, and verified every file 769ms
[+] records state and a JSON report, and cleans up the unencrypted staging copy 23ms
[+] second run picks up new log lines and skips the restore test when not due 3.81s
[+] RestoreTest mode restores the latest snapshot and checks every hash 844ms
[+] Verify mode reads back all data 831ms
[+] Restore-LogBackup.ps1 restores one source and proves it intact 1.7s
[+] StaleCheck is OK right after a good backup 17ms
[+] missing required source: ALERT, the other source is still backed up, and retention does not delete the complete snapshot 12.25s
[+] wrong password: ALERT with the password hint, nothing deleted 3.62s
[+] repository unreachable: ALERT with the repository hint (never auto-initialised) 687ms
[+] tampered repository data is detected by verification 8.06s
[+] recovery test catches files that changed between manifest and backup 4.85s
[+] does not apply retention when verification fails 8.06s
[+] keeps exactly what the policy says (daily 3 + monthly 2) 10.12s
[+] loads the shipped example config and resolves paths against the project root 16ms
[+] leaves repository URLs alone and expands environment variables 3ms
[+] fills in defaults for optional sections 9ms
[+] rejects no sources 72ms
[+] rejects duplicate source names 7ms
[+] rejects unknown source type 7ms
[+] rejects bad rclone remote 5ms
[+] rejects retention keeping nothing 5ms
[+] rejects negative retention 5ms
[+] rejects missing repository 7ms
[+] rejects invalid JSON 6ms
[+] quotes process arguments: abc 7ms
[+] quotes process arguments: a b 1ms
[+] quotes process arguments: a"b 1ms
[+] quotes process arguments: C:\x y\ 1ms
[+] quotes process arguments:  1ms
[+] converts Windows paths to restic snapshot paths 5ms
[+] parses newline-delimited JSON and skips other lines 3ms
[+] copies a local folder with robocopy and honours excludes 64ms
[+] mirrors deletions (a log removed at the source is removed from staging) 64ms
[+] raises ALERT for a missing required source, WARNING for an optional one, and drops stale staged data 11ms
[+] warns when a source has fewer files than the minimum 20ms
[+] stages cloud folders with rclone and reports rclone failures with a hint 44ms
[+] writes a SHA-256 manifest of every staged file (but not of itself) 8ms
[+] passes when every file is present with the same size 4ms
[+] reports missing, resized and unexpected files 2ms
[+] ignores files outside the staging folder 1ms
[+] overall status is the worst step 4ms
[+] maps exit codes to OK 4ms
[+] maps exit codes to WARNING 1ms
[+] maps exit codes to ALERT 1ms
[+] gives a root-cause hint for wrong password 60ms
[+] gives a root-cause hint for missing repository 1ms
[+] gives a root-cause hint for old restic missing repo 5ms
[+] gives a root-cause hint for lock 1ms
[+] gives a root-cause hint for damaged data 1ms
[+] gives a root-cause hint for disk full 12ms
[+] gives a root-cause hint for incomplete snapshot 1ms
[+] works out when a task is due (string and DateTime inputs) 31ms
[+] builds retention arguments only for non-zero keeps 12ms
[+] blocks a second run and releases on exit 16ms
[+] takes over a stale lock 9ms
[+] saves and reloads state atomically 8ms
[+] prefers RESTIC_PASSWORD, else reads the DPAPI file, else explains what to do 16ms
[+] reads the webhook from the configured environment variable 4ms
[+] passes repository and password only through the child environment 33ms
[+] explains a missing restic binary 6ms
[+] formats a readable message with hints for failed steps only 7ms
[+] posts JSON with text, status and steps 121ms
[+] retries 3 times, then reports failure without throwing 32ms
[+] does nothing when no webhook is configured 2ms
[+] StaleCheck: ALERT when no backup was ever recorded 41ms
[+] StaleCheck: OK when recent, ALERT when older than the limit 65ms
[+] exit 3 with a hint when the password is missing, and writes a JSON report 55ms
[+] exit 3 when another run holds the lock, and leaves that lock alone 88ms
[+] exit 3 for an invalid config (no report, no crash) 27ms
[+] ALERT from restic is reported with the hint, and the webhook is called 148ms
[+] does not send a webhook for OK runs unless onSuccess is set 40ms
[+] writes a daily log file 40ms
```

## End-to-end demo (Windows PowerShell 5.1)

```
### 1. First backup (recovery test forced)
[OK] Log backup 'test-backup' on TESTHOST (Backup, run 20261125T202022Z-c1d493)
  [OK     ] copy:app-logs: 4 file(s), 0.01 MB staged
  [OK     ] copy:sys-logs: 4 file(s), 0 MB staged
  [OK     ] backup: Snapshot 40e0afc3: 9 file(s), 9 new, 0 changed
  [OK     ] verify: 8 file(s) match the manifest; repository check passed (structure + all data read back).
  [OK     ] retention: Kept 1 snapshot(s), removed 0 (daily 14, weekly 8, monthly 12).
  [OK     ] restore-test: Restored snapshot 20261125T202022Z-c1d493: 8 file(s) verified by SHA-256.
  [OK     ] staleness: Last good backup 0.0 h ago.
exit code: 0

### 2. Next day: one log grew
[OK] Log backup 'test-backup' on TESTHOST (Backup, run 20261125T202027Z-f5ce6a)
  [OK     ] copy:app-logs: 4 file(s), 0.01 MB staged
  [OK     ] copy:sys-logs: 4 file(s), 0 MB staged
  [OK     ] backup: Snapshot 2f0dd9da: 9 file(s), 0 new, 2 changed
  [OK     ] verify: 8 file(s) match the manifest; repository check passed (structure + 10% of data read back).
  [OK     ] retention: Kept 2 snapshot(s), removed 0 (daily 14, weekly 8, monthly 12).
  [OK     ] staleness: Last good backup 0.0 h ago.
exit code: 0

### 3. A log folder disappeared
[ALERT] Log backup 'test-backup' on TESTHOST (Backup, run 20261125T202030Z-6c3f71)
  [OK     ] copy:app-logs: 4 file(s), 0.01 MB staged
  [ALERT  ] copy:sys-logs: Source folder not found: <temp>\src\sys
            -> Check the path exists and the drive/share is connected, and that the task account can read it.
  [OK     ] backup: Snapshot a9aea376: 5 file(s), 0 new, 1 changed
  [OK     ] verify: 4 file(s) match the manifest; repository check passed (structure + 10% of data read back).
  [SKIPPED] retention: Skipped: 1 source(s) failed in this run, so no older snapshot is removed.
  [OK     ] staleness: Last good backup 0.0 h ago.
exit code: 2

### 4. Repository file damaged on disk, full verification
[ALERT] Log backup 'test-backup' on TESTHOST (Verify, run 20261125T202032Z-5b5b14)
  [ALERT  ] verify: restic check --read-data failed (exit 1).
            -> Repository data is damaged: do NOT prune; run restic check --read-data, then follow docs/RECOVERY.md (repair section).
exit code: 2

Demo outcome as expected (exit codes 0,0,2,2).
```
