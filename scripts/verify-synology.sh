#!/bin/sh
set -eu
PATH="/usr/local/bin:$PATH"
export PATH

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE_PATH="${WARDROBE_BASE_PATH:-$ROOT}"

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

env_value() {
  key="$1"
  fallback="$2"
  value="$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' .env)"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

wait_for_healthy() {
  container="$1"
  attempts=0
  while [ "$attempts" -lt 20 ]; do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container" 2>/dev/null || true)"
    [ "$health" = healthy ] && return 0
    [ "$health" = unhealthy ] && return 1
    attempts=$((attempts + 1))
    sleep 2
  done
  return 1
}

cd "$ROOT"
test -f .env || fail 'Missing Wardrobe .env.'
test -z "$(git status --porcelain)" || fail 'Refusing verification with an uncommitted deployment checkout.'

container="$(env_value WARDROBE_CONTAINER_NAME wardrobe)"
backup="$(env_value WARDROBE_BACKUP_CONTAINER_NAME wardrobe-backup)"
updater="$(env_value WARDROBE_UPDATE_CONTAINER_NAME wardrobe-update-check)"
bind_address="$(env_value WARDROBE_BIND_ADDRESS 127.0.0.1)"
host_port="$(env_value WARDROBE_HOST_PORT 4173)"
data_path="$(env_value WARDROBE_DATA_HOST_PATH "$BASE_PATH/data")"
backup_path="$(env_value WARDROBE_BACKUP_HOST_PATH "$BASE_PATH/backups")"
state_path="$(env_value WARDROBE_UPDATE_STATE_HOST_PATH "$BASE_PATH/update-state")"
candidates_path="$(env_value WARDROBE_CANDIDATES_ROOT "$BASE_PATH/candidates")"
revision="$(git rev-parse HEAD)"

for directory in "$data_path" "$backup_path" "$state_path" "$candidates_path"; do
  test -d "$directory" || fail "Missing persistent directory: $directory"
done
test -f "$data_path/model-reference.png" || fail 'Missing persistent model reference.'

wait_for_healthy "$container" || fail 'Wardrobe is not healthy before the restart test.'
docker restart "$container" >/dev/null
wait_for_healthy "$container" || fail 'Wardrobe did not become healthy after the restart test.'

docker exec -e WARDROBE_BACKUP_ONCE=1 "$backup" /bin/sh /usr/local/bin/wardrobe-backup
set -- $(cat "$backup_path/.last-success")
test "$#" -eq 2 || fail 'Backup status file has an invalid format.'
last_backup="$2"
docker exec "$backup" tar -tzf "/backups/$last_backup" >/dev/null

published_ip="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4173/tcp") 0).HostIp}}' "$container")"
published_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4173/tcp") 0).HostPort}}' "$container")"
test "$published_ip" = "$bind_address" || fail 'Wardrobe is not bound to the configured address.'
test "$published_port" = "$host_port" || fail 'Wardrobe is not published on the configured host port.'
image_revision="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container")"
test "$image_revision" = "$revision" || fail 'Running image revision does not match the Git checkout.'

docker exec -e UPDATE_CHECK_ONCE=1 "$updater" node /app/scripts/update-check.mjs
grep -q "\"deployed_revision\":\"$revision\"" "$state_path/update-status.json" || fail 'Update status does not match the deployed revision.'

./scripts/test-rollback.sh
wait_for_healthy "$container" || fail 'Wardrobe is not healthy after the isolated rollback test.'
test "$(git rev-parse HEAD)" = "$revision" || fail 'Production Git revision changed during the rollback test.'
test "$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container")" = "$revision" || fail 'Production image changed during the rollback test.'

printf '%s\n' 'Wardrobe verification passed: storage, restart, backup, bind address, update check, and isolated rollback are verified.'
