#!/bin/bash
# backup.sh — Backup de N carpetas + N bases de datos PostgreSQL
#              → comprimir → cifrar (AES-256) → subir a pCloud
#
# Configuración 100% por variables de entorno.
# Sin variables = sin backups.
set -euo pipefail

# ─── Cargar .env si existe ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && set -a && . "$SCRIPT_DIR/.env" && set +a

# ─── Globales (con defaults) ──────────────────────────────
PCLOUD_REMOTE="${PCLOUD_REMOTE:-pcloud}"
PCLOUD_PATH="${PCLOUD_PATH:-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"

TMPDIR="/tmp/backup-$$"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# ─── Funciones ────────────────────────────────────────────

gpg_cipher() {
  if [ -n "$GPG_PASSPHRASE" ]; then
    gpg --batch --passphrase "$GPG_PASSPHRASE" --symmetric --cipher-algo AES256 "$@"
  else
    gpg --symmetric --cipher-algo AES256 "$@"
  fi
}

upload_and_cleanup() {
  local name="$1"
  local archive="$2"
  local remote_path="${PCLOUD_REMOTE}:${PCLOUD_PATH}/${name}/"

  rclone copy "$archive" "$remote_path"
  echo "  -> ${remote_path}$(basename "$archive")"
  rclone delete --min-age "${RETENTION_DAYS}d" "$remote_path" 2>/dev/null || true
}

backup_folder() {
  local name="$1"
  local path="$2"
  local srcdir="$TMPDIR/$name"
  local archive="$TMPDIR/${name}-${TIMESTAMP}.tar.gz"
  local encrypted="${archive}.gpg"

  echo "── Folder: $name ──"
  mkdir -p "$srcdir"

  if [ ! -d "$path" ]; then
    echo "  ⚠ Directory not found: $path, skipping."
    return
  fi

  echo "  [1/3] Copying files…"
  rsync -a "$path"/ "$srcdir/"

  echo "  [2/3] Compressing…"
  tar -czf "$archive" -C "$srcdir" .

  echo "  [3/3] Encrypting…"
  gpg_cipher --output "$encrypted" "$archive"

  upload_and_cleanup "$name" "$encrypted"
  echo "  ✓ Done"
}

backup_postgres() {
  local name="$1"
  local host="$2"
  local port="$3"
  local user="$4"
  local pass="$5"
  local database="$6"
  local connector="$7"  # "docker" | "network"
  local srcdir="$TMPDIR/$name"
  local archive="$TMPDIR/${name}-${TIMESTAMP}.tar.gz"
  local encrypted="${archive}.gpg"

  echo "── PostgreSQL: $name ──"
  mkdir -p "$srcdir"

  echo "  [1/3] Dumping database…"
  local dump_cmd="pg_dump -U $user -d $database --clean --if-exists --no-owner"
  if [ "$connector" = "docker" ]; then
    docker exec "$host" bash -c "PGPASSWORD='$pass' $dump_cmd" > "$srcdir/db-dump.sql"
  else
    PGPASSWORD="$pass" $dump_cmd -h "$host" -p "$port" > "$srcdir/db-dump.sql"
  fi

  echo "  [2/3] Compressing…"
  tar -czf "$archive" -C "$srcdir" .

  echo "  [3/3] Encrypting…"
  gpg_cipher --output "$encrypted" "$archive"

  upload_and_cleanup "$name" "$encrypted"
  echo "  ✓ Done"
}

# ─── Descubrimiento dinámico de backups ──────────────────
# Folder: FOLDER_BACKUP_<N>_NAME + FOLDER_BACKUP_<N>_PATH
# Postgres: DB_BACKUP_<N>_NAME + _HOST + _PORT + _USER + _PASS + _DATABASE + _TYPE

i=1
while :; do
  name_var="FOLDER_BACKUP_${i}_NAME"
  path_var="FOLDER_BACKUP_${i}_PATH"
  name="${!name_var:-}"
  path="${!path_var:-}"
  [ -z "$name" ] && break
  backup_folder "$name" "$path"
  i=$((i + 1))
done

i=1
while :; do
  name_var="DB_BACKUP_${i}_NAME"
  host_var="DB_BACKUP_${i}_HOST"
  port_var="DB_BACKUP_${i}_PORT"
  user_var="DB_BACKUP_${i}_USER"
  pass_var="DB_BACKUP_${i}_PASS"
  db_var="DB_BACKUP_${i}_DATABASE"
  type_var="DB_BACKUP_${i}_TYPE"

  name="${!name_var:-}"
  host="${!host_var:-}"
  port="${!port_var:-5432}"
  user="${!user_var:-}"
  pass="${!pass_var:-}"
  database="${!db_var:-}"
  connector="${!type_var:-}"

  [ -z "$name" ] && break
  backup_postgres "$name" "$host" "$port" "$user" "$pass" "$database" "$connector"
  i=$((i + 1))
done

echo "✅ Todos los backups completados."
