#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
EXPECTED_DATA_PATH='/volume1/docker/wardrobe/data'

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
  docker exec wardrobe node -e "const http=require('node:http');const request=http.get('http://127.0.0.1:4173/api/import/config',(response)=>{let body='';response.on('data',(chunk)=>body+=chunk);response.on('end',()=>{try{const value=JSON.parse(body);process.exit(response.statusCode===200&&value.ready===true?0:1)}catch{process.exit(1)}})});request.setTimeout(4000,()=>request.destroy(new Error('timeout')));request.on('error',()=>process.exit(1));"
}

cd "$ROOT"
test -f .env || fail 'Missing .env. Create it from .env.example before deployment.'
bind_address="$(awk -F= '$1 == "WARDROBE_BIND_ADDRESS" { print substr($0, index($0, "=") + 1); exit }' .env)"
test -n "$bind_address" || fail 'WARDROBE_BIND_ADDRESS must be set to the Synology LAN IP.'
data_path="$(awk -F= '$1 == "WARDROBE_DATA_HOST_PATH" { print substr($0, index($0, "=") + 1); exit }' .env)"
test "$data_path" = "$EXPECTED_DATA_PATH" || fail "WARDROBE_DATA_HOST_PATH must be $EXPECTED_DATA_PATH."
for directory in /volume1/docker/wardrobe/data /volume1/docker/wardrobe/backups /volume1/docker/wardrobe/update-state /volume1/docker/wardrobe/candidates; do
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
wait_for_healthy wardrobe || fail 'Wardrobe did not become healthy within 40 seconds.'
api_smoke_test || fail 'Wardrobe is healthy but the configured importer is not ready. Check the hidden API key entry and data/model-reference.png.'

compose restart wardrobe
wait_for_healthy wardrobe || fail 'Wardrobe did not return healthy after its restart test.'
api_smoke_test || fail 'Wardrobe importer failed after the restart test.'

compose run --rm --no-deps -e WARDROBE_BACKUP_ONCE=1 wardrobe-backup
last_backup="$(awk 'NR == 1 { print $2 }' /volume1/docker/wardrobe/backups/.last-success)"
test -n "$last_backup" || fail 'Backup status file was not written.'
docker exec wardrobe-backup tar -tzf "/backups/$last_backup" >/dev/null

published_ip="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4173/tcp") 0).HostIp}}' wardrobe)"
published_port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4173/tcp") 0).HostPort}}' wardrobe)"
test "$published_ip" = "$bind_address" || fail 'Container port is not bound only to the configured LAN IP.'
test "$published_port" = '4173' || fail 'Container is not published on host port 4173.'
image_revision="$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' wardrobe)"
test "$image_revision" = "$revision" || fail 'Running container image does not report the expected Git revision.'

printf 'Deployment verification passed for revision %s.\n' "$revision"
