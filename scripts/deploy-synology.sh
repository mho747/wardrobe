#!/bin/sh
set -eu
PATH="/usr/local/bin:$PATH"
export PATH

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE_PATH="${WARDROBE_BASE_PATH:-/volume1/docker/wardrobe}"
EXPECTED_DATA_PATH="$BASE_PATH/data"

fail() { printf '%s\n' "$*" >&2; exit 1; }

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    fail 'Docker Compose is not installed on this Synology.'
  fi
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
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container" 2>/dev/null || true)"
    [ "$status" = 'healthy' ] && return 0
    [ "$status" = 'unhealthy' ] && return 1
    attempts=$((attempts + 1))
    sleep 2
  done
  return 1
}

api_smoke_test() {
  docker exec "$1" node -e "const http=require('node:http');const request=http.get('http://127.0.0.1:4173/api/import/config',(response)=>{let body='';response.on('data',(chunk)=>body+=chunk);response.on('end',()=>{try{const value=JSON.parse(body);process.exit(response.statusCode===200&&value.ready===true?0:1)}catch{process.exit(1)}})});request.setTimeout(4000,()=>request.destroy(new Error('timeout')));request.on('error',()=>process.exit(1));"
}

cd "$ROOT"
test -f .env || fail 'Missing .env. Create it from .env.example before deployment.'
container_name="$(env_value WARDROBE_CONTAINER_NAME wardrobe)"
backup_container_name="$(env_value WARDROBE_BACKUP_CONTAINER_NAME wardrobe-backup)"
bind_address="$(awk -F= '$1 == "WARDROBE_BIND_ADDRESS" { print substr($0, index($0, "=") + 1); exit }' .env)"
test -n "$bind_address" || fail 'WARDROBE_BIND_ADDRESS must be set to the Synology LAN IP.'
data_path="$(awk -F= '$1 == "WARDROBE_DATA_HOST_PATH" { print substr($0, index($0, "=") + 1); exit }' .env)"
test "$data_path" = "$EXPECTED_DATA_PATH" || fail "WARDROBE_DATA_HOST_PATH must be $EXPECTED_DATA_PATH."
for directory in "$BASE_PATH/data" "$BASE_PATH/backups" "$BASE_PATH/update-state" "$BASE_PATH/candidates"; do
  mkdir -p "$directory"
  chown 1000:1000 "$directory"
  chmod 700 "$directory"
done
revision="$(git rev-parse HEAD)"
revision_file=".env.revision.$$"
awk -v revision="$revision" '
  /^WARDROBE_REVISION=/ { print "WARDROBE_REVISION=" revision; found=1; next }
  { print }
  END { if (!found) print "WARDROBE_REVISION=" revision }
' .env > "$revision_file"
mv "$revision_file" .env
chmod 600 .env

compose up -d --build
if [ "${WARDROBE_ROLLBACK_TEST:-0}" = '1' ] && [ -n "${WARDROBE_TEST_FORCE_DEPLOY_FAILURE_FILE:-}" ] && [ -f "${WARDROBE_TEST_FORCE_DEPLOY_FAILURE_FILE}" ]; then
  case "${WARDROBE_TEST_FORCE_DEPLOY_FAILURE_FILE}" in
    "$BASE_PATH"/.rollback-failure-*) rm -f -- "${WARDROBE_TEST_FORCE_DEPLOY_FAILURE_FILE}" ;;
    *) fail 'Refusing an intentional rollback-test failure outside the isolated test base path.' ;;
  esac
  fail 'Intentional isolated rollback-test deployment failure.'
fi
wait_for_healthy "$container_name" || fail 'Wardrobe did not become healthy within 40 seconds.'
api_smoke_test "$container_name" || fail 'Wardrobe is healthy but the configured importer is not ready. Check the hidden API key entry and data/model-reference.png.'

compose restart wardrobe
wait_for_healthy "$container_name" || fail 'Wardrobe did not return healthy after its restart test.'
api_smoke_test "$container_name" || fail 'Wardrobe importer failed after the restart test.'

docker exec -e WARDROBE_BACKUP_ONCE=1 "$backup_container_name" /bin/sh /usr/local/bin/wardrobe-backup
last_backup="$(awk 'NR == 1 { print $2 }' "$BASE_PATH/backups/.last-success")"
test -n "$last_backup" || fail 'Backup status file was not written.'
docker exec "$backup_container_name" tar -tzf "/backups/$last_backup" >/dev/null

published_ip="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4173/tcp") 0).HostIp}}' "$container_name")"
published_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4173/tcp") 0).HostPort}}' "$container_name")"
test "$published_ip" = "$bind_address" || fail 'Container port is not bound only to the configured LAN IP.'
test "$published_port" = '4173' || fail 'Container is not published on host port 4173.'
image_revision="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$container_name")"
test "$image_revision" = "$revision" || fail 'Running container image does not report the expected Git revision.'

printf 'Deployment verification passed for revision %s.\n' "$revision"
