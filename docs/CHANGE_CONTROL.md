# Change control

Applies to code, `config\backup.config.json` (sources, retention, thresholds), the restic version and the scheduled tasks.

1. **Scope.** Add an entry to `CHANGELOG.md` → *Unreleased*: what changes, why, the risk, and the rollback.
2. **Test.**
   - `.\tests\Invoke-Tests.ps1 -Integration` must pass. It runs PSScriptAnalyzer (0 findings), the unit tests, and the integration tests against real restic. A code change adds a test that fails without it.
   - Config change: `.\src\Invoke-LogBackup.ps1 -Mode StaleCheck` (loads and validates the config), then one manual run with `-ForceRestoreTest`.
   - **Retention change:** check what it would delete first: `restic forget --tag logbackup --keep-daily N ... --dry-run`. Removing snapshots cannot be undone.
   - **restic upgrade:** pin the new version and hash in `Install-Restic.ps1`, run the full test suite, then `-Mode Verify` against the production repository before scheduling.
3. **Deploy.** Commit and tag (`vX.Y.Z`), then pull or copy to the backup machine. Scheduled tasks only need re-registering if the schedule, account or paths changed.
4. **Verify.** `Start-ScheduledTask -TaskName 'LogBackup - Daily'`; the run report must be OK.
5. **Roll back.**
   - Code/config: `git checkout v<previous>` and run once by hand.
   - Schedule: `.\scripts\Unregister-BackupTask.ps1`, then re-register the previous settings.
   - restic: re-run `Install-Restic.ps1 -Version <previous>`. Repositories stay compatible within the 0.x repository format v2.
   - The repository itself is never rolled back. That is why destructive changes (retention, prune) get a `--dry-run` first.

## Record

| Date | Version | Change | Tests | Rollback tested |
|---|---|---|---|---|
| 2026-11-26 | 1.0.0 | First release | 59 unit + 16 integration (CI) | `Unregister-BackupTask.ps1 -WhatIf` |
