#!/bin/sh
set -eu
PATH="/usr/local/bin:$PATH"
export PATH

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CANDIDATES_ROOT="${WARDROBE_CANDIDATES_ROOT:-/volume1/docker/wardrobe/candidates}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_REPOSITORY_URL="${GITHUB_REPOSITORY_URL:-https://github.com/mho747/wardrobe.git}"

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

test_candidate_api() {
  docker exec "$1" node -e "const http=require('node:http');const request=http.get('http://127.0.0.1:4173/api/import/config',(response)=>{let body='';response.on('data',(chunk)=>body+=chunk);response.on('end',()=>{try{const value=JSON.parse(body);process.exit(response.statusCode===200&&typeof value.ready==='boolean'&&typeof value.hasApiKey==='boolean'&&typeof value.hasModelReference==='boolean'?0:1)}catch{process.exit(1)}})});request.setTimeout(4000,()=>request.destroy(new Error('timeout')));request.on('error',()=>process.exit(1));"
}

cd "$ROOT"
test -f .env || fail 'Missing .env. Create it from .env.example with the production secret only on the Synology.'
test -z "$(git status --porcelain)" || fail 'Refusing update test: the deployment checkout has uncommitted changes.'
git remote get-url origin >/dev/null 2>&1 || git remote add origin "$GITHUB_REPOSITORY_URL"
git fetch --prune origin "$GITHUB_BRANCH"

current_revision="$(git rev-parse HEAD)"
candidate_revision="$(git rev-parse "origin/$GITHUB_BRANCH")"
if [ -n "${WARDROBE_TEST_CANDIDATE_REVISION:-}" ]; then
  [ "${WARDROBE_ROLLBACK_TEST:-0}" = '1' ] || fail 'Refusing a non-GitHub candidate outside the isolated rollback test.'
  case "${WARDROBE_BASE_PATH:-}" in
    /volume1/docker/wardrobe/candidates/rollback-test-*) ;;
    *) fail 'Refusing a non-GitHub candidate outside the isolated rollback-test path.' ;;
  esac
  candidate_revision="$(git rev-parse --verify "${WARDROBE_TEST_CANDIDATE_REVISION}^{commit}")"
fi
if [ "$current_revision" = "$candidate_revision" ]; then
  printf 'No GitHub update is available. Current revision: %s\n' "$current_revision"
  exit 0
fi

git merge-base --is-ancestor "$current_revision" "$candidate_revision" || fail 'The GitHub update is not a fast-forward from the deployed GitHub revision.'
changed_files="$(git diff --name-only "$current_revision..$candidate_revision")"
printf '%s\n' "$changed_files"

if printf '%s\n' "$changed_files" | grep -E '(^|/)(Dockerfile|compose\.ya?ml|package(-lock)?\.json|\.env\.example|vite\.config\.[^/]+|scripts/)' >/dev/null && [ "${ALLOW_SENSITIVE_CANDIDATE:-0}" != '1' ]; then
  printf '%s\n' 'REQUIRES_APPROVAL: update changes dependencies, container/configuration, or execution scripts.' >&2
  exit 3
fi
if git diff --unified=0 "$current_revision..$candidate_revision" -- src scripts vite.config.mjs | grep -E '(^[+-].*(OPENAI|/api/|model|auth|security|https?://))' >/dev/null && [ "${ALLOW_SENSITIVE_CANDIDATE:-0}" != '1' ]; then
  printf '%s\n' 'REQUIRES_APPROVAL: update may affect API use, models, costs, or security.' >&2
  exit 3
fi

run_id="$(date -u +%Y%m%d%H%M%S)-${candidate_revision%????????????????????????????????}"
candidate_dir="$CANDIDATES_ROOT/$run_id"
candidate_data="$candidate_dir/data"
candidate_backups="$candidate_dir/backups"
candidate_state="$candidate_dir/update-state"
candidate_container="wardrobe-candidate-$run_id"
candidate_backup_container="wardrobe-candidate-backup-$run_id"
candidate_update_container="wardrobe-candidate-update-$run_id"
candidate_project="wardrobe-candidate-$run_id"
candidate_port="${WARDROBE_CANDIDATE_PORT:-4174}"

case "$candidate_port" in
  ''|*[!0-9]*) fail 'WARDROBE_CANDIDATE_PORT must be a numeric host port.' ;;
esac
if docker ps --format '{{.Ports}}' | grep -F ":$candidate_port->" >/dev/null; then
  fail "Candidate host port $candidate_port is already in use; no candidate was started."
fi

mkdir -p "$CANDIDATES_ROOT"
git worktree add --detach "$candidate_dir" "$candidate_revision"
cleanup() {
  compose -p "$candidate_project" -f "$candidate_dir/compose.yaml" down --remove-orphans >/dev/null 2>&1 || true
  git -C "$ROOT" worktree remove --force "$candidate_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$candidate_data" "$candidate_backups" "$candidate_state"
chown 1000:1000 "$candidate_data" "$candidate_backups" "$candidate_state"
chmod 700 "$candidate_data" "$candidate_backups" "$candidate_state"
printf '%s\n' \
  'OPENAI_API_KEY=' \
  'OPENAI_VISION_MODEL=gpt-5.4-mini' \
  'OPENAI_IMAGE_MODEL=gpt-image-2' \
  'OPENAI_IMAGE_QUALITY=high' \
  'WARDROBE_BIND_ADDRESS=127.0.0.1' \
  "WARDROBE_HOST_PORT=$candidate_port" \
  "WARDROBE_DATA_HOST_PATH=$candidate_data" \
  "WARDROBE_BACKUP_HOST_PATH=$candidate_backups" \
  "WARDROBE_UPDATE_STATE_HOST_PATH=$candidate_state" \
  "WARDROBE_CONTAINER_NAME=$candidate_container" \
  "WARDROBE_BACKUP_CONTAINER_NAME=$candidate_backup_container" \
  "WARDROBE_UPDATE_CONTAINER_NAME=$candidate_update_container" \
  "WARDROBE_REVISION=$candidate_revision" > "$candidate_dir/.env"
chmod 600 "$candidate_dir/.env"

compose -p "$candidate_project" -f "$candidate_dir/compose.yaml" up -d --build wardrobe
wait_for_healthy "$candidate_container" || fail 'Candidate container did not become healthy within 40 seconds.'
test_candidate_api "$candidate_container" || fail 'Candidate API smoke test failed.'
printf 'Candidate passed: %s. No production files, data, or containers were changed.\n' "$candidate_revision"
