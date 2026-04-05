#!/bin/sh
set -eu

COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-serviceradar}"
VOLUME_PREFIX="${SERVICERADAR_VOLUME_PREFIX:-serviceradar}"
DATA_VOLUME="${CNPG_DATA_VOLUME:-${VOLUME_PREFIX}_cnpg-data}"
CREDENTIALS_VOLUME="${CNPG_CREDENTIALS_VOLUME:-${VOLUME_PREFIX}_cnpg-credentials}"
MIGRATOR_DATA_DIR="${CNPG_MIGRATOR_DATA_DIR:-}"
MIGRATOR_CREDENTIALS_DIR="${CNPG_MIGRATOR_CREDENTIALS_DIR:-}"

SOURCE_IMAGE="${CNPG_SOURCE_IMAGE:-registry.carverauto.dev/serviceradar/serviceradar-cnpg:16.6.0-sr5}"
TARGET_IMAGE="${CNPG_TARGET_IMAGE:-${CNPG_IMAGE:-registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.3.0-sr2-a78b3afd}}"
EXPECTED_TARGET_MAJOR="${CNPG_EXPECTED_PG_MAJOR:-18}"
SOURCE_DATA_PATH="${CNPG_SOURCE_DATA_PATH:-/var/lib/postgresql/data}"
TARGET_DATA_PATH="${CNPG_TARGET_DATA_PATH:-/var/lib/postgresql/18/docker}"

SOURCE_DB="${CNPG_DATABASE:-serviceradar}"
SOURCE_SUPERUSER="${CNPG_SUPERUSER:-}"
SOURCE_SUPERUSER_PASSWORD="${CNPG_SUPERUSER_PASSWORD:-}"
APP_PASSWORD="${CNPG_PASSWORD:-}"
LEGACY_SUPERUSER="${CNPG_LEGACY_SUPERUSER:-serviceradar}"
LEGACY_SUPERUSER_PASSWORD="${CNPG_LEGACY_SUPERUSER_PASSWORD:-serviceradar}"
LEGACY_APP_PASSWORD="${CNPG_LEGACY_APP_PASSWORD:-serviceradar}"
FORCE="${FORCE:-false}"
ALLOW_RUNNING_COMPOSE_PROJECT="${CNPG_ALLOW_RUNNING_COMPOSE_PROJECT:-false}"

TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_VOLUME="${DATA_VOLUME}-pg16-backup-${TIMESTAMP}"
STAGE_VOLUME="${DATA_VOLUME}-pg18-stage-${TIMESTAMP}"
CREDENTIALS_BACKUP_VOLUME="${CREDENTIALS_VOLUME}-backup-${TIMESTAMP}"
DUMP_FILE="/tmp/serviceradar-cnpg-pg18-dump-${TIMESTAMP}.sql"
SOURCE_CONTAINER="serviceradar-cnpg16-migrate-${TIMESTAMP}"
TARGET_CONTAINER="serviceradar-cnpg18-migrate-${TIMESTAMP}"
BOOTSTRAP_USER="migration_admin"
BOOTSTRAP_PASSWORD="$(od -An -N 32 -tx1 /dev/urandom | tr -d ' \n')"

cleanup() {
  rm -f "$DUMP_FILE"
  docker rm -f "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
  docker rm -f "$TARGET_CONTAINER" >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

log() {
  printf '%s\n' "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

confirm() {
  if [ "$FORCE" = "true" ]; then
    return
  fi

  printf '%s [y/N] ' "$1" >&2
  read -r answer || true
  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      die "Aborted."
      ;;
  esac
}

ensure_volume_exists() {
  volume="$1"
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    die "Docker volume $volume does not exist."
  fi
}

copy_volume() {
  from_volume="$1"
  to_volume="$2"

  docker volume create "$to_volume" >/dev/null
  docker run --rm \
    -v "${from_volume}:/from:ro" \
    -v "${to_volume}:/to" \
    alpine:3.20 \
    sh -ceu '
      rm -rf /to/.??* /to/* 2>/dev/null || true
      cp -a /from/. /to/
    '
}

read_optional_file_from_volume() {
  volume="$1"
  filename="$2"

  if [ "$volume" = "$CREDENTIALS_VOLUME" ] && [ -n "$MIGRATOR_CREDENTIALS_DIR" ] && [ -f "${MIGRATOR_CREDENTIALS_DIR}/${filename}" ]; then
    tr -d '\r\n' < "${MIGRATOR_CREDENTIALS_DIR}/${filename}"
    return
  fi

  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    return
  fi

  docker run --rm \
    -v "${volume}:/data:ro" \
    alpine:3.20 \
    sh -ceu "
      if [ -f /data/${filename} ]; then
        tr -d '\\r\\n' < /data/${filename}
      fi
    " 2>/dev/null || true
}

detect_source_superuser() {
  if [ -n "$SOURCE_SUPERUSER" ]; then
    printf '%s' "$SOURCE_SUPERUSER"
    return
  fi

  detected="$(read_optional_file_from_volume "$CREDENTIALS_VOLUME" "superuser-username")"
  if [ -n "$detected" ]; then
    printf '%s' "$detected"
    return
  fi

  printf '%s' "$LEGACY_SUPERUSER"
}

detect_source_superuser_password() {
  if [ -n "$SOURCE_SUPERUSER_PASSWORD" ]; then
    printf '%s' "$SOURCE_SUPERUSER_PASSWORD"
    return
  fi

  detected="$(read_optional_file_from_volume "$CREDENTIALS_VOLUME" "superuser-password")"
  if [ -n "$detected" ]; then
    printf '%s' "$detected"
    return
  fi

  printf '%s' "$LEGACY_SUPERUSER_PASSWORD"
}

seed_credentials_volume() {
  if ! docker volume inspect "$CREDENTIALS_VOLUME" >/dev/null 2>&1; then
    docker volume create "$CREDENTIALS_VOLUME" >/dev/null
  fi

  docker run --rm \
    -e CNPG_SUPERUSER="${SOURCE_SUPERUSER}" \
    -e CNPG_SUPERUSER_PASSWORD="${SOURCE_SUPERUSER_PASSWORD}" \
    -e CNPG_PASSWORD="${APP_PASSWORD}" \
    -v "${CREDENTIALS_VOLUME}:/etc/serviceradar/cnpg" \
    alpine:3.20 \
    sh -ceu '
      umask 077
      mkdir -p /etc/serviceradar/cnpg
      printf "%s" "$CNPG_SUPERUSER" > /etc/serviceradar/cnpg/superuser-username
      printf "%s" "$CNPG_SUPERUSER_PASSWORD" > /etc/serviceradar/cnpg/superuser-password
      printf "%s" "$CNPG_PASSWORD" > /etc/serviceradar/cnpg/serviceradar-password
      chmod 0644 /etc/serviceradar/cnpg/superuser-username \
        /etc/serviceradar/cnpg/superuser-password \
        /etc/serviceradar/cnpg/serviceradar-password
    '
}

wait_for_ready() {
  container="$1"
  user="$2"
  password="$3"
  database="$4"

  tries=0
  while [ "$tries" -lt 60 ]; do
    if docker exec \
      -e PGPASSWORD="$password" \
      "$container" \
      pg_isready -h 127.0.0.1 -U "$user" -d "$database" >/dev/null 2>&1; then
      return
    fi

    sleep 2
    tries=$((tries + 1))
  done

  docker logs "$container" >&2 || true
  die "Timed out waiting for $container to become ready."
}

detect_source_version() {
  if [ -n "$MIGRATOR_DATA_DIR" ] && [ -f "${MIGRATOR_DATA_DIR}/PG_VERSION" ]; then
    tr -d '\r\n' < "${MIGRATOR_DATA_DIR}/PG_VERSION"
    return
  fi

  docker run --rm \
    -v "${DATA_VOLUME}:/data:ro" \
    alpine:3.20 \
    sh -ceu '
      if [ -f /data/PG_VERSION ]; then
        tr -d "\r\n" < /data/PG_VERSION
      fi
    ' 2>/dev/null || true
}

ensure_compose_stack_stopped() {
  if [ "$ALLOW_RUNNING_COMPOSE_PROJECT" = "true" ]; then
    return
  fi

  if [ -n "$(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" -q)" ]; then
    die "Stop the running Docker Compose project ${COMPOSE_PROJECT} before migrating CNPG volumes."
  fi
}

ensure_volume_exists "$DATA_VOLUME"
ensure_compose_stack_stopped

actual_version="$(detect_source_version)"
case "$actual_version" in
  "")
    log "No existing PostgreSQL data detected in ${DATA_VOLUME}; skipping CNPG major migration."
    exit 0
    ;;
  16|16.*)
    ;;
  ${EXPECTED_TARGET_MAJOR}|${EXPECTED_TARGET_MAJOR}.*)
    log "Data volume ${DATA_VOLUME} already uses PostgreSQL ${actual_version}; skipping CNPG major migration."
    exit 0
    ;;
  *)
    die "Volume ${DATA_VOLUME} reports PostgreSQL ${actual_version}; this workflow only supports PG16 -> PG${EXPECTED_TARGET_MAJOR}."
    ;;
esac

SOURCE_SUPERUSER="$(detect_source_superuser)"
SOURCE_SUPERUSER_PASSWORD="$(detect_source_superuser_password)"

if [ -z "$APP_PASSWORD" ]; then
  APP_PASSWORD="$(read_optional_file_from_volume "$CREDENTIALS_VOLUME" "serviceradar-password")"
fi

if [ -z "$APP_PASSWORD" ]; then
  APP_PASSWORD="$LEGACY_APP_PASSWORD"
fi

confirm "This will migrate Docker volume ${DATA_VOLUME} from PG16 to PG${EXPECTED_TARGET_MAJOR}, create backup volume ${BACKUP_VOLUME}, and overwrite ${DATA_VOLUME} with migrated PG${EXPECTED_TARGET_MAJOR} data. Continue?"

log "Creating backup of ${DATA_VOLUME} at ${BACKUP_VOLUME}"
copy_volume "$DATA_VOLUME" "$BACKUP_VOLUME"

if docker volume inspect "$CREDENTIALS_VOLUME" >/dev/null 2>&1; then
  log "Creating backup of ${CREDENTIALS_VOLUME} at ${CREDENTIALS_BACKUP_VOLUME}"
  copy_volume "$CREDENTIALS_VOLUME" "$CREDENTIALS_BACKUP_VOLUME"
fi

log "Starting temporary PG16 source container from ${DATA_VOLUME}"
docker run -d --rm \
  --name "$SOURCE_CONTAINER" \
  --user 0:0 \
  -v "${DATA_VOLUME}:${SOURCE_DATA_PATH}" \
  "$SOURCE_IMAGE" \
  postgres -c shared_preload_libraries=timescaledb,age >/dev/null

wait_for_ready "$SOURCE_CONTAINER" "$SOURCE_SUPERUSER" "$SOURCE_SUPERUSER_PASSWORD" "$SOURCE_DB"

log "Dumping source cluster via pg_dumpall"
docker exec \
  -e PGPASSWORD="$SOURCE_SUPERUSER_PASSWORD" \
  "$SOURCE_CONTAINER" \
  pg_dumpall -h 127.0.0.1 -U "$SOURCE_SUPERUSER" > "$DUMP_FILE"

log "Preparing empty PG${EXPECTED_TARGET_MAJOR} target volume ${STAGE_VOLUME}"
docker volume create "$STAGE_VOLUME" >/dev/null

docker run -d --rm \
  --name "$TARGET_CONTAINER" \
  --user 0:0 \
  -e POSTGRES_USER="$BOOTSTRAP_USER" \
  -e POSTGRES_PASSWORD="$BOOTSTRAP_PASSWORD" \
  -e POSTGRES_DB=postgres \
  -v "${STAGE_VOLUME}:${TARGET_DATA_PATH}" \
  "$TARGET_IMAGE" \
  postgres -c shared_preload_libraries=timescaledb,age >/dev/null

wait_for_ready "$TARGET_CONTAINER" "$BOOTSTRAP_USER" "$BOOTSTRAP_PASSWORD" postgres

log "Restoring dump into temporary PG${EXPECTED_TARGET_MAJOR} target volume"
docker exec -i \
  -e PGPASSWORD="$BOOTSTRAP_PASSWORD" \
  "$TARGET_CONTAINER" \
  psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U "$BOOTSTRAP_USER" -d postgres < "$DUMP_FILE"

log "Stopping temporary migration containers"
docker rm -f "$SOURCE_CONTAINER" >/dev/null
docker rm -f "$TARGET_CONTAINER" >/dev/null

log "Promoting migrated PG${EXPECTED_TARGET_MAJOR} data back into ${DATA_VOLUME}"
docker run --rm \
  -v "${STAGE_VOLUME}:/from:ro" \
  -v "${DATA_VOLUME}:/to" \
  alpine:3.20 \
  sh -ceu '
    rm -rf /to/.??* /to/* 2>/dev/null || true
    cp -a /from/. /to/
  '

log "Seeding or normalizing ${CREDENTIALS_VOLUME} for the upgraded stack"
seed_credentials_volume

docker volume rm "$STAGE_VOLUME" >/dev/null 2>&1 || true

log "Migration complete."
log "Backup volumes:"
log "  data: ${BACKUP_VOLUME}"
if docker volume inspect "$CREDENTIALS_BACKUP_VOLUME" >/dev/null 2>&1; then
  log "  credentials: ${CREDENTIALS_BACKUP_VOLUME}"
fi
log "You can now start the Docker Compose stack on PG${EXPECTED_TARGET_MAJOR}."
