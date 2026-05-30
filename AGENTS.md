# homelab-backup

## What it is

Single `backup.sh` that backs up folders + PostgreSQL databases → tar.gz → GPG AES-256 → pCloud via rclone.

## Config

- Copy `.env.example` → `.env` (`.env` is gitignored).
- Backups are discovered dynamically by numeric index: `FOLDER_BACKUP_1_NAME`, `DB_BACKUP_1_NAME`, etc. Indices start at **1** and must be sequential with no gaps; discovery stops at the first missing `_NAME`.
- `GPG_PASSPHRASE` optional — empty = interactive prompt per file.
- `DB_BACKUP_N_TYPE`: `docker` (runs `pg_dump` via `docker exec`) or `network` (TCP/IP, all flags passed to `pg_dump` directly).

## Run

```bash
bash backup.sh
```

No other scripts, no tests, no CI, no package manager.

## Dependencies (must be installed)

bash, rsync, gpg, tar, rclone, pg_dump (postgresql-client), docker (for `docker`-type DB backups).

## Retention

Retention is a side effect of `rclone delete --min-age "${RETENTION_DAYS}d"` after each upload. No separate cleanup job.

## Script quirks

- `set -euo pipefail` — any failure aborts the whole run.
- Uses `/tmp/backup-$$` as temp dir; auto-cleaned on exit via `trap`.
- File naming: `<name>-<YYYYMMDD_HHMMSS>.tar.gz.gpg`.
