# Helpers for postgres-reliability demos. Source after common.env.

wait_for_postgres() {
  local name="$1"
  local seconds="${2:-60}"
  local i
  for i in $(seq 1 "${seconds}"); do
    if ! docker ps --format '{{.Names}}' | grep -qx "${name}"; then
      echo "コンテナ ${name} が動いていません。ログ:" >&2
      docker logs "${name}" >&2 || true
      return 1
    fi
    if docker exec "${name}" pg_isready -U "${PG_SUPERUSER}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "${name} の起動待ちがタイムアウトしました。ログ:" >&2
  docker logs "${name}" >&2 || true
  return 1
}

# Extra mounts are not the image VOLUME, so they stay root-owned. The archiver
# and pg_basebackup run as uid 999 (postgres).
chown_extra_mounts() {
  docker exec "${PG_CONTAINER}" bash -c \
    'chown postgres:postgres /archive /backup && chmod 0775 /archive /backup'
}
