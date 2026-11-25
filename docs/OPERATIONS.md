# Operations runbook

## Daily (1 minute)
Nothing to do when there is no message: OK runs are silent unless `notify.onSuccess` is on. Every WARNING or ALERT arrives in the alert channel with the failed step and a hint.

Check the task result any time:
```powershell
Get-ScheduledTaskInfo -TaskName 'LogBackup - Daily' | Select-Object LastRunTime, LastTaskResult, NextRunTime
```
`LastTaskResult`: 0 = OK, 1 = WARNING, 2 = ALERT, 3 = could not run.

## Reading an alert
```
[ALERT] Log backup 'log-backup' on LOGSRV01 (Backup, run 20261126T220001Z-3f9a1c)
  [OK     ] copy:app-logs: 412 file(s), 38.2 MB staged
  [ALERT  ] copy:cloud-audit-logs: rclone copy failed (exit 1): ... token expired
            -> Check the rclone remote 'gdrive-logs' with 'rclone lsd' (token expired? folder renamed?).
  [OK     ] backup: Snapshot 4f1c2a9b: 412 file(s), 9 new, 3 changed
  ...
```
Each line is one step. The `->` line is the most likely cause. Full details: `work\logs\backup-<date>.log` and `work\reports\run-<runId>.json`.

| Step | ALERT / WARNING means | Do |
|---|---|---|
| `copy:<source>` ALERT "not found" | Folder missing, drive or share not connected, path changed | Fix the path or connection; if the folder was retired, remove it from the config (change control) |
| `copy:<source>` WARNING "Only 0 file(s)" | Logging has stopped, or it now writes somewhere else | Check the application that writes the logs |
| `copy:<source>` ALERT rclone | Cloud token expired or remote renamed | `rclone config reconnect <remote>:`, then `rclone lsd <remote>:` |
| `backup` ALERT wrong password | DPAPI file belongs to another user/machine, or was replaced | Re-run `Initialize-BackupRepository.ps1` as the task account (password from the password manager) |
| `backup` ALERT repository not found | Backup drive or NAS offline, or path changed | Reconnect it. **Never** run `restic init` on a path that should already hold backups |
| `backup` ALERT locked | A previous run crashed while holding a restic lock | Make sure no backup is running, then `restic unlock` |
| `backup` WARNING incomplete | Some files were locked or deleted during the copy | Usually harmless for logs; if it repeats, exclude the active file (`*.lock`) |
| `verify` ALERT does not match the manifest | Data changed or was lost between staging and snapshot | Run again with `-ForceRestoreTest`; if it repeats, check the disk and the antivirus exclusions |
| `verify` / `restore-test` ALERT damaged / hash mismatch | Repository corruption | Follow **RECOVERY.md → Damaged repository**. Retention is skipped automatically while verify fails |
| `retention` WARNING | forget/prune failed; the backup itself is fine | Check free space and locks; the next run tries again |
| `staleness` ALERT | No good backup within `maxHoursSinceSuccess` | Check the Daily task is enabled, the machine was on, and the latest run report |
| `run` ALERT could not start | Config error, missing restic or password file, lock held | Follow the hint. Exit code 3 |

After fixing anything, run once by hand: `.\src\Invoke-LogBackup.ps1` (add `-ForceRestoreTest` after storage problems).

## Weekly
- The automatic recovery test runs once a week. Confirm the latest run report shows `restore-test: OK`.

## Monthly
- `.\src\Invoke-LogBackup.ps1 -Mode Verify` reads back **all** repository data (also done automatically every `fullReadEveryDays`).
- Check repository size and free space: `restic stats --mode raw-data`.
- Check the webhook still works: `.\scripts\Set-BackupWebhook.ps1 -SendTest`.

## Quarterly
- **Manual restore drill** on a different machine with the escrowed password ([RECOVERY.md](RECOVERY.md)). Record it in the table there.
- Review sources against the systems that exist now; review retention against policy.
- Update restic: change `-Version` and the pinned hash in `Install-Restic.ps1` through change control, run the tests, then install.

## Where things are

| Path | What |
|---|---|
| `work\logs\backup-YYYYMMDD.log` | Human-readable log (UTC) |
| `work\reports\run-<runId>.json` | Full result of each run |
| `work\state\state.json` | Last success, last recovery test, last full read, last snapshot |
| `work\staging\` | Temporary unencrypted copy, deleted after each run (`cleanStagingAfterRun`) |
| `secrets\` | DPAPI-protected password and webhook (git-ignored) |
| repository | Encrypted snapshots: the only copy that matters |
