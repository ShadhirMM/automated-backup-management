# Changelog

## [1.0.0] - 2026-11-26
- Encrypted log backups with restic 0.20.0 (pinned and hash-verified installer).
- Sources: local/UNC folders (robocopy mirror with excludes) and cloud folders (rclone copy --checksum); optional vs required sources.
- SHA-256 manifest of every file, stored inside the snapshot.
- Verification after every backup: manifest vs snapshot listing, `restic check`, data read-back subset; full read every N days.
- Retention (keep daily/weekly/monthly) with prune, only after a verified backup.
- Automatic recovery test (restore + re-hash) every N days; `Restore-LogBackup.ps1` with hash verification.
- OK/WARNING/ALERT reports with root-cause hints: webhook (3 attempts), JSON run report, daily log, optional Windows Event Log; staleness watchdog.
- DPAPI-protected password and webhook; password kept as SecureString until restic starts.
- Task Scheduler register/unregister scripts with pre-flight check and -WhatIf.
- Tests: 59 unit + 16 integration (real restic) on Windows PowerShell 5.1 and PowerShell 7; PSScriptAnalyzer clean.
