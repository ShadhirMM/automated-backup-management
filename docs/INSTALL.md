# Installation

About 30 minutes on a Windows 10/11 or Windows Server 2019+ machine. Windows PowerShell 5.1 (built in) or PowerShell 7.

## 1. Get the project
Copy or clone the repository to a local folder, e.g. `C:\Tools\automated-backup-management`. The folder must be writable by the account that will run the backups (it holds `work\` and `secrets\`).

## 2. Install restic
```powershell
.\scripts\Install-Restic.ps1
```
This downloads the official restic release (pinned version 0.20.0), checks its SHA-256 against both the published `SHA256SUMS` and the hash pinned in the script, and installs it to `tools\bin\restic.exe`.

Optional: install [rclone](https://rclone.org) and configure a remote (`rclone config`) if you back up **cloud** log folders. Check it with `rclone lsd <remote>:`.

## 3. Edit the config
`config\backup.config.json`:

| Key | Meaning |
|---|---|
| `sources[]` | One entry per log folder. `type: "path"` for local or UNC folders (`path`), `type: "rclone"` for cloud folders (`remote`, e.g. `gdrive-logs:IT/AuditLogs`). `exclude` takes wildcards. `optional: true` turns a missing folder into a WARNING instead of an ALERT |
| `repository` | Where the encrypted backups live: a folder on another disk/NAS (`E:\Backups\log-repo`, `\\nas\backups\logs`) or any restic backend (`rclone:remote:path`, `s3:...`) |
| `retention` | `keepDaily` / `keepWeekly` / `keepMonthly` snapshots |
| `verify` | `readDataSubsetPercent` of the data is read back on every run; a full read every `fullReadEveryDays` |
| `restoreTest.everyDays` | How often the automatic recovery test runs (`sampleSize` 0 = every file) |
| `thresholds` | `maxHoursSinceSuccess` (staleness ALERT), `minFilesPerSource` |
| `notify` | `webhookEnv` / `webhookFile` (the URL itself is never in the config), `onSuccess` |
| `eventLog.enabled` | Also write to the Windows Application log (create the source once as admin: `New-EventLog -LogName Application -Source LogBackup`) |

Put the repository on **different storage** from the logs, and preferably in another location.

## 4. Create the repository and store the password
Log on as the account that will run the task (a dedicated service account is best), then:
```powershell
.\scripts\Initialize-BackupRepository.ps1
```
- Asks for the password twice (at least 16 characters).
- Creates the encrypted repository. If one already exists, it only checks the password; it never re-initialises an existing repository.
- Saves the password with Windows DPAPI to `secrets\repo-password.xml`. Only this user on this machine can read the file.
- **Put the password in the company password manager now** (key escrow). Without it, the backups cannot be restored.

## 5. Alerts
```powershell
.\scripts\Set-BackupWebhook.ps1 -SendTest      # stores the Slack/Teams webhook with DPAPI and sends a test
```
Or set an environment variable `BACKUP_WEBHOOK_URL` for the task account.

## 6. First run by hand
```powershell
.\src\Invoke-LogBackup.ps1 -ForceRestoreTest
```
Expected: `[OK] Log backup ...` with every step OK, exit code 0. Read `work\logs\backup-<date>.log` and `work\reports\run-*.json`.

## 7. Schedule it
```powershell
.\scripts\Register-BackupTask.ps1 -Time 02:00 -WhatIf   # preview
.\scripts\Register-BackupTask.ps1 -Time 02:00           # pre-flight check, then registers both tasks
Start-ScheduledTask -TaskName 'LogBackup - Daily'        # test now
```

| Task | When | Does |
|---|---|---|
| LogBackup - Daily | every day at `-Time` | backup → verify → retention → recovery test when due |
| LogBackup - Watchdog | every 6 h | ALERT if the last good backup is older than `maxHoursSinceSuccess` |

The tasks run as the registering user, only while that user is logged on. For a server, open each task and choose *Run whether user is logged on or not* (Windows stores the account password). Rollback: `.\scripts\Unregister-BackupTask.ps1`.

## 8. Practise a restore
Follow [RECOVERY.md](RECOVERY.md) once, now, before you rely on the backups.
