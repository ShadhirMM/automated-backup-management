# Recovery procedure

Use this to get log files back, for example for an audit, an incident investigation or after a disk failure. Restores never overwrite anything. They go into an empty folder that you choose, and every file is checked against the SHA-256 manifest stored in the same snapshot.

## What you need
- A Windows machine with this project and restic (`scripts\Install-Restic.ps1`).
- Access to the repository (the backup drive, share or cloud location in `repository`).
- **The repository password.** On the backup server it is in the DPAPI file. On any other machine, take it from the **company password manager** (key escrow) and set it for the session only:
  ```powershell
  $env:RESTIC_PASSWORD = Read-Host 'Repository password' -MaskInput   # PowerShell 7; on 5.1 paste carefully
  ```
  Remove it afterwards with `Remove-Item Env:RESTIC_PASSWORD`.

## 1. Find the right snapshot
```powershell
.\scripts\Restore-LogBackup.ps1 -List
```
```
Id       Time                              Host      Tags
--       ----                              ----      ----
1a2b3c4d 2026-11-24T02:00:12.345+04:00     LOGSRV01  logbackup,job:log-backup,run:20261123T220012Z-ab12cd
...
```
Snapshots are kept per the retention policy: daily for 14 days, weekly for 8 weeks, monthly for 12 months (see config). To find a specific file across snapshots:
```powershell
$env:RESTIC_REPOSITORY = 'E:\Backups\log-repo'   # repository from the config
.\tools\bin\restic.exe find "app-2026-11-03.log"
```

## 2. Restore
Restore one source from the latest snapshot:
```powershell
.\scripts\Restore-LogBackup.ps1 -Source app-logs -Target D:\Restore
```
Restore everything from a specific snapshot:
```powershell
.\scripts\Restore-LogBackup.ps1 -Snapshot 1a2b3c4d -Target D:\Restore
```
Result: `D:\Restore\<snapshot-id>\<source>\...`, plus `_backup-manifest.json`.

## 3. Check the result
The script prints one of:
- `Restored N file(s) to ...; all SHA-256 hashes match the backup manifest.` The files are exactly what was backed up.
- `NOT INTACT: <file>` warnings and an error. **Do not use those files as evidence.** Go to *Damaged repository* below.

For evidence handling, keep `_backup-manifest.json` with the restored files: it records the hash of every file at backup time.

## 4. Clean up
Restored logs are **unencrypted**. Delete them, or move them to an encrypted location, when you are done. Remove `RESTIC_PASSWORD` from the session.

---

## Damaged repository
Signs: verify or restore-test ALERTs mentioning *damaged*, *Pack ID does not match* or *ciphertext verification failed*.

1. **Stop changes:** disable the daily task (`Disable-ScheduledTask -TaskName 'LogBackup - Daily'`). **Do not run prune or forget.**
2. Copy the whole repository folder somewhere safe before trying any repair.
3. Find the extent: `restic check --read-data`.
4. Restore what you need from snapshots that are still intact (older snapshots often share no damaged packs). Use `restic restore <id> --target ...` and check the hashes with the manifest.
5. Repair, following the restic documentation for your version: `restic repair index`, then `restic repair snapshots --forget`. Afterwards run `restic check --read-data` again.
6. If the damage came from the disk, move the repository to new storage (`restic copy` into a fresh repository) and update `repository` in the config.
7. Re-enable the task, force a run with `-ForceRestoreTest`, and record the incident.

## Lost password
There is **no recovery** without the password. This is how the encryption is meant to work. That is why the password must be in the company password manager from day one (see SECURITY.md). If the DPAPI file is lost (new server, or the account changed) but the password is still known, run `scripts\Initialize-BackupRepository.ps1` again: it detects the existing repository and only re-creates the password file.

## Recovery test record

The automated recovery test runs every `restoreTest.everyDays` days (default 7). It restores the newest snapshot into a temporary folder, re-hashes every file, compares the hashes with the manifest, and deletes the restored copy. Its result is in every run report (`work\reports\run-*.json`, step `restore-test`). Also do a **manual** restore once a quarter, following steps 1–4 on a different machine, and record it here:

| Date | Snapshot | Source | Files | Result | By |
|---|---|---|---|---|---|
| _to fill after go-live_ | | | | | |
