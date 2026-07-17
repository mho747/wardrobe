#!/bin/sh
set -eu
PATH="/usr/local/bin:$PATH"
export PATH

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE_PATH=/volume1/docker/wardrobe

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

[ "$(id -u)" -eq 0 ] || fail 'Run this script with sudo on the Synology.'
[ "$ROOT" = /volume1/docker/wardrobe/repository ] || fail 'Refusing verification outside the Wardrobe production checkout.'
test "$(git -C "$ROOT" remote get-url origin)" = 'https://github.com/mho747/wardrobe.git' || fail 'Unexpected GitHub remote.'
test -z "$(git -C "$ROOT" status --porcelain)" || fail 'Refusing verification with an uncommitted production checkout.'

cd "$ROOT"
container="$(env_value WARDROBE_CONTAINER_NAME wardrobe)"
backup="$(env_value WARDROBE_BACKUP_CONTAINER_NAME wardrobe-backup)"
updater="$(env_value WARDROBE_UPDATE_CONTAINER_NAME wardrobe-update-check)"
bind_address="$(env_value WARDROBE_BIND_ADDRESS '')"
revision="$(git rev-parse HEAD)"

for directory in "$BASE_PATH/data" "$BASE_PATH/backups" "$BASE_PATH/update-state" "$BASE_PATH/candidates"; do
  test "$(stat -c '%u:%g:%a' "$directory")" = '1000:1000:700' || fail "Unexpected ownership or mode for $directory."
done
test -f "$BASE_PATH/data/model-reference.png" || fail 'Missing persistent model reference.'
test "$(stat -c '%a' .env)" = '600' || fail 'Wardrobe .env must have mode 0600.'

wait_for_healthy "$container" || fail 'Wardrobe is not healthy before the restart test.'
docker restart "$container" >/dev/null
wait_for_healthy "$container" || fail 'Wardrobe did not become healthy after the restart test.'

docker exec -e WARDROBE_BACKUP_ONCE=1 "$backup" /bin/sh /usr/local/bin/wardrobe-backup
set -- $(cat "$BASE_PATH/backups/.last-success")
test "$#" -eq 2 || fail 'Backup status file has an invalid format.'
last_backup="$2"
docker exec "$backup" tar -tzf "/backups/$last_backup" >/dev/null

published_ip="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4173/tcp") 0).HostIp}}' "$container")"
published_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4173/tcp") 0).HostPort}}' "$container")"
test -n "$bind_address" || fail 'WARDROBE_BIND_ADDRESS is missing.'
test "$published_ip" = "$bind_address" || fail 'Wardrobe is not bound only to the configured LAN IP.'
test "$published_port" = 4173 || fail 'Wardrobe is not published on host port 4173.'
image_revision="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container")"
test "$image_revision" = "$revision" || fail 'Running image revision does not match the Git checkout.'

docker exec -e UPDATE_CHECK_ONCE=1 "$updater" node /app/scripts/update-check.mjs
grep -q "\"status\":\"current\"" "$BASE_PATH/update-state/update-status.json" || fail 'GitHub update check is not current.'
grep -q "\"deployed_revision\":\"$revision\"" "$BASE_PATH/update-state/update-status.json" || fail 'Update status does not match the deployed revision.'

./scripts/test-rollback.sh
wait_for_healthy "$container" || fail 'Wardrobe is not healthy after the isolated rollback test.'
test "$(git rev-parse HEAD)" = "$revision" || fail 'Production Git revision changed during the rollback test.'
test "$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container")" = "$revision" || fail 'Production image changed during the rollback test.'

printf '%s\n' 'Wardrobe verification passed: storage, restart, backup, LAN binding, update check, and isolated rollback are verified.'
