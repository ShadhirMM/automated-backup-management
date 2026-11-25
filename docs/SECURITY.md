# Security design

## Encryption: use a vetted tool, don't invent one
Backups are stored in a **restic** repository. restic encrypts all data and metadata with AES-256 in counter mode, authenticates it with Poly1305-AES, and derives keys from the password with scrypt ([restic design](https://restic.readthedocs.io/en/stable/100_references.html#design)). File names, folder structure and contents are all encrypted. An integration test proves log text is not readable in the repository files. This project contains **no custom cryptography**: it only orchestrates restic.

The restic binary is downloaded from the official GitHub release, and its SHA-256 is checked against `SHA256SUMS` **and** against a hash pinned in `scripts\Install-Restic.ps1`. Upgrades change the pin through change control.

## The repository password
| Rule | How |
|---|---|
| Never in plain text on disk | Stored with Windows DPAPI (`Export-Clixml` SecureString). Only the same user on the same machine can decrypt it. A unit test confirms the file does not contain the password |
| Never on a command line or in logs | Kept as a SecureString inside the module. Turned into text only inside `Invoke-Restic`, and given to the restic **child process environment** only. The current session's environment is not changed (unit-tested). Nothing logs it |
| CI / service accounts | `RESTIC_PASSWORD` environment variable (GitHub Actions secret / task account) |
| **Key escrow** | The password must also be in the company password manager. **A lost password means lost backups**: restic has no back door |
| Strength | `Initialize-BackupRepository.ps1` enforces at least 16 characters |

## Least privilege
- Run the tasks as a dedicated account with: **read** on the log sources, **write** on the repository and the project's `work\` folder, **nothing else**. No local admin rights are needed (except once, to create the Event Log source if you use it).
- Repository on separate storage from the sources. For protection against ransomware, use storage the backup account can write to but not delete from (an append-only rest-server, object lock on S3, or NAS snapshots), and keep `forget/prune` on a separate, more trusted account. These are documented options, not built in to v1.

## Unencrypted copies
- **Staging** (`work\staging`) holds a plain copy during the run and is deleted afterwards (`cleanStagingAfterRun: true`). Keep `work\` on a local disk with ACLs that only the backup account and admins can read.
- **Restore tests** restore into `work\tmp` and delete the copy in a `finally` block, even when the test fails.
- **Manual restores** produce plain files on purpose; RECOVERY.md says to delete them after use.

## Integrity
- SHA-256 manifest of every staged file, stored **inside** the snapshot it describes.
- After each backup: snapshot listing vs manifest (every file, every size), `restic check`, and a read-back of `readDataSubsetPercent` of the data; a full read every `fullReadEveryDays`.
- Weekly recovery test: restore + re-hash every file + compare with the manifest.
- Retention never runs after a failed verification, or when any source failed to copy, so a bad or partial snapshot cannot trigger the deletion of good old ones (both integration-tested).

## Webhook
Anyone with the webhook URL can post to the channel. It is stored with DPAPI (`Set-BackupWebhook.ps1`) or in an environment variable, never in the config or the repository. Messages contain host and folder names, file counts and errors, never log **contents**.

## Repo hygiene
`.gitignore` excludes `tools\bin`, `work\`, `secrets\` and test results. Tests and the demo use generated fake logs and throw-away passwords only.
