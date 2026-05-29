#!/bin/bash
# Backup genérico: DB dump + datos → comprimir → cifrar → pCloud
set -euo pipefail

# ── Configuración de servicios ───────────────────────────
# Añade aquí nuevos servicios copiando el bloque
# db_*:   opcional — si no hay DB, pon db_host=""
# dirs:   carpetas a incluir (separadas por espacio)
# docker: nombre del contenedor si la DB corre en Docker (vacio si acceso directo)
# ────────────────────────────────────────────────────────

SERVICES=()

# Servicio 1: Immich
IMMICH_NAME="immich"
IMMICH_DB_HOST=""         # vacío porque usa Docker
IMMICH_DB_PORT="5432"
IMMICH_DB_USER="${IMMICH_DB_USERNAME:-immich}"
IMMICH_DB_PASS="${IMMICH_DB_PASSWORD:-}"
IMMICH_DB_NAME="${IMMICH_DB_DATABASE_NAME:-immich}"
IMMICH_DB_DOCKER="immich-database"
IMMICH_DIRS="/home/ismael/immich/data"
SERVICES+=("IMMICH")

# Servicio 2: Synology DB (PostgreSQL accesible por red)
SYNO_NAME="synology-db"
SYNO_DB_HOST="192.168.1.X"        # ← CAMBIAR IP del Synology
SYNO_DB_PORT="5432"
SYNO_DB_USER="usuario"
SYNO_DB_PASS="contraseña"
SYNO_DB_NAME="nombre_bd"
SYNO_DB_DOCKER=""                  # acceso directo, no Docker
SYNO_DIRS=""
SERVICES+=("SYNO")

# ── Config global ────────────────────────────────────────
PCLOUD_REMOTE="pcloud"
PCLOUD_PATH="backups"
TMPDIR="/tmp/backup-$$"
RETENTION_DAYS=30

# ─────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

backup_service() {
  local prefix="$1"
  local name_var="${prefix}_NAME"
  local db_host_var="${prefix}_DB_HOST"
  local db_port_var="${prefix}_DB_PORT"
  local db_user_var="${prefix}_DB_USER"
  local db_pass_var="${prefix}_DB_PASS"
  local db_name_var="${prefix}_DB_NAME"
  local db_docker_var="${prefix}_DB_DOCKER"
  local dirs_var="${prefix}_DIRS"

  local name="${!name_var}"
  local db_host="${!db_host_var}"
  local db_port="${!db_port_var}"
  local db_user="${!db_user_var}"
  local db_pass="${!db_pass_var}"
  local db_name="${!db_name_var}"
  local db_docker="${!db_docker_var}"
  local dirs="${!dirs_var}"

  local srcdir="$TMPDIR/$name"
  mkdir -p "$srcdir"

  ARCHIVE="$TMPDIR/${name}-backup-${TIMESTAMP}.tar.gz"
  ENCRYPTED="${ARCHIVE}.gpg"

  echo "── $name ──"

  # 1. Dump DB
  if [ -n "$db_host" ] || [ -n "$db_docker" ]; then
    echo "  [1/4] Dumping database…"
    local dump_cmd="pg_dump -U $db_user -d $db_name --clean --if-exists --no-owner"
    if [ -n "$db_docker" ]; then
      docker exec "$db_docker" bash -c "PGPASSWORD='$db_pass' $dump_cmd" > "$srcdir/db-dump.sql"
    else
      PGPASSWORD="$db_pass" $dump_cmd -h "$db_host" -p "$db_port" > "$srcdir/db-dump.sql" 2>/dev/null
    fi
  else
    echo "  [1/4] No database configured, skipping."
  fi

  # 2. Copiar directorios
  if [ -n "$dirs" ]; then
    echo "  [2/4] Copying data directories…"
    for d in $dirs; do
      if [ -d "$d" ]; then
        local basename=$(basename "$d")
        rsync -a --info=progress2 "$d"/ "$srcdir/$basename/"
      fi
    done
  else
    echo "  [2/4] No data directories configured."
  fi

  # 3. Comprimir
  echo "  [3/4] Compressing…"
  tar -czf "$ARCHIVE" -C "$srcdir" .

  # 4. Cifrar
  echo "  [4/4] Encrypting…"
  gpg --symmetric --cipher-algo AES256 --output "$ENCRYPTED" "$ARCHIVE"

  # 5. Subir
  echo "  Uploading to pCloud…"
  remote_path="${PCLOUD_REMOTE}:${PCLOUD_PATH}/${name}/"
  rclone copy "$ENCRYPTED" "$remote_path"

  echo "  Done: ${remote_path}${name}-backup-${TIMESTAMP}.tar.gz.gpg"
}

# ── Ejecutar todos los servicios ─────────────────────────
for svc in "${SERVICES[@]}"; do
  backup_service "$svc"
done

# Limpieza remota (por servicio)
for svc in "${SERVICES[@]}"; do
  local name_var="${svc}_NAME"
  local name="${!name_var}"
  rclone delete --min-age "${RETENTION_DAYS}d" "${PCLOUD_REMOTE}:${PCLOUD_PATH}/${name}/" 2>/dev/null || true
done

echo "✅ Todos los backups completados."
