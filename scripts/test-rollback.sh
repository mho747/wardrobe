#!/bin/sh
set -eu
PATH="/usr/local/bin:$PATH"
export PATH

GITHUB_REPOSITORY_URL="${GITHUB_REPOSITORY_URL:-https://github.com/mho747/wardrobe.git}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
CANDIDATES_ROOT="${WARDROBE_CANDIDATES_ROOT:-/volume1/docker/wardrobe/candidates}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TEST_BASE="$CANDIDATES_ROOT/rollback-test-$run_id"
TEST_REPOSITORY="$TEST_BASE/repository"
TEST_PROJECT="wardrobe-rollback-test-$run_id"
TEST_CONTAINER="wardrobe-rollback-test-$run_id"
TEST_BACKUP_CONTAINER="wardrobe-rollback-backup-test-$run_id"
TEST_UPDATE_CONTAINER="wardrobe-rollback-update-test-$run_id"
TEST_PORT="${WARDROBE_ROLLBACK_TEST_PORT:-4175}"
CANDIDATE_PORT="${WARDROBE_CANDIDATE_PORT:-4174}"
force_file="$TEST_BASE/.rollback-failure-$run_id"

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

port_is_available() {
  port="$1"
  case "$port" in
    ''|*[!0-9]*) fail 'Rollback-test ports must be numeric.' ;;
  esac
  if docker ps --format '{{.Ports}}' | grep -F ":$port->" >/dev/null; then
    fail "Rollback-test port $port is already in use; no test was started."
  fi
}

cleanup() {
  if [ -f "$TEST_REPOSITORY/compose.yaml" ]; then
    compose -p "$TEST_PROJECT" -f "$TEST_REPOSITORY/compose.yaml" down --remove-orphans >/dev/null 2>&1 || true
  fi
  case "$TEST_BASE" in
    "$CANDIDATES_ROOT"/rollback-test-*) rm -rf -- "$TEST_BASE" ;;
    *) printf '%s\n' 'Refusing rollback-test cleanup outside its isolated candidate directory.' >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

test ! -e "$TEST_BASE" || fail "Rollback-test path already exists: $TEST_BASE"
port_is_available "$TEST_PORT"
port_is_available "$CANDIDATE_PORT"
for container in "$TEST_CONTAINER" "$TEST_BACKUP_CONTAINER" "$TEST_UPDATE_CONTAINER"; do
  ! docker inspect "$container" >/dev/null 2>&1 || fail "Rollback-test container already exists: $container"
done

mkdir -p "$TEST_BASE"
git clone --branch "$GITHUB_BRANCH" --depth 1 "$GITHUB_REPOSITORY_URL" "$TEST_REPOSITORY"
test "$(git -C "$TEST_REPOSITORY" remote get-url origin)" = "$GITHUB_REPOSITORY_URL" || fail 'Rollback test was not cloned from the configured GitHub source.'

mkdir -p "$TEST_BASE/data" "$TEST_BASE/backups" "$TEST_BASE/update-state" "$TEST_BASE/candidates"
chown 1000:1000 "$TEST_BASE/data" "$TEST_BASE/backups" "$TEST_BASE/update-state" "$TEST_BASE/candidates"
chmod 700 "$TEST_BASE/data" "$TEST_BASE/backups" "$TEST_BASE/update-state" "$TEST_BASE/candidates"
printf 'rollback-test-reference\n' > "$TEST_BASE/data/model-reference.png"
chown 1000:1000 "$TEST_BASE/data/model-reference.png"
chmod 600 "$TEST_BASE/data/model-reference.png"

printf '%s\n' \
  'OPENAI_API_KEY=rollback-test-placeholder' \
  'OPENAI_VISION_MODEL=gpt-5.4-mini' \
  'OPENAI_IMAGE_MODEL=gpt-image-2' \
  'OPENAI_IMAGE_QUALITY=high' \
  'WARDROBE_BIND_ADDRESS=127.0.0.1' \
  "WARDROBE_HOST_PORT=$TEST_PORT" \
  "WARDROBE_DATA_HOST_PATH=$TEST_BASE/data" \
  "WARDROBE_BACKUP_HOST_PATH=$TEST_BASE/backups" \
  "WARDROBE_UPDATE_STATE_HOST_PATH=$TEST_BASE/update-state" \
  "WARDROBE_CONTAINER_NAME=$TEST_CONTAINER" \
  "WARDROBE_BACKUP_CONTAINER_NAME=$TEST_BACKUP_CONTAINER" \
  "WARDROBE_UPDATE_CONTAINER_NAME=$TEST_UPDATE_CONTAINER" \
  "GITHUB_REPOSITORY_URL=$GITHUB_REPOSITORY_URL" \
  "GITHUB_BRANCH=$GITHUB_BRANCH" > "$TEST_REPOSITORY/.env"
chmod 600 "$TEST_REPOSITORY/.env"

export COMPOSE_PROJECT_NAME="$TEST_PROJECT"
(
  cd "$TEST_REPOSITORY"
  WARDROBE_BASE_PATH="$TEST_BASE" ./scripts/deploy-synology.sh
)
previous_revision="$(git -C "$TEST_REPOSITORY" rev-parse HEAD)"

git -C "$TEST_REPOSITORY" config user.name 'Wardrobe rollback test'
git -C "$TEST_REPOSITORY" config user.email 'rollback-test@localhost'
printf '%s\n' "$run_id" > "$TEST_REPOSITORY/.rollback-test-marker"
git -C "$TEST_REPOSITORY" add .rollback-test-marker
git -C "$TEST_REPOSITORY" commit -m 'Temporary isolated rollback test candidate' >/dev/null
candidate_revision="$(git -C "$TEST_REPOSITORY" rev-parse HEAD)"
touch "$force_file"

if (
  cd "$TEST_REPOSITORY"
  WARDROBE_ROLLBACK_TEST=1 \
  WARDROBE_BASE_PATH="$TEST_BASE" \
  WARDROBE_CANDIDATES_ROOT="$TEST_BASE/candidates" \
  WARDROBE_CANDIDATE_PORT="$CANDIDATE_PORT" \
  WARDROBE_TEST_CANDIDATE_REVISION="$candidate_revision" \
  WARDROBE_TEST_FORCE_DEPLOY_FAILURE_FILE="$force_file" \
  ./scripts/apply-update.sh --approved-sensitive
); then
  fail 'Rollback test expected the intentional candidate deployment failure.'
fi

test ! -e "$force_file" || fail 'The intentional failure hook was not consumed.'
test "$(git -C "$TEST_REPOSITORY" rev-parse HEAD)" = "$previous_revision" || fail 'Automatic rollback did not restore the previous Git revision.'
test "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$TEST_CONTAINER")" = 'healthy' || fail 'Rollback container is not healthy.'
test "$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$TEST_CONTAINER")" = "$previous_revision" || fail 'Rollback container does not report the previous image revision.'
docker exec "$TEST_CONTAINER" node -e "const http=require('node:http');const request=http.get('http://127.0.0.1:4173/api/import/config',(response)=>{let body='';response.on('data',(chunk)=>body+=chunk);response.on('end',()=>{try{const value=JSON.parse(body);process.exit(response.statusCode===200&&value.ready===true?0:1)}catch{process.exit(1)}})});request.setTimeout(4000,()=>request.destroy(new Error('timeout')));request.on('error',()=>process.exit(1));"

printf 'Isolated rollback test passed. Git revision %s was restored automatically; no production container, data, port 4173, or OpenAI request was used.\n' "$previous_revision"
