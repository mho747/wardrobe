#!/bin/sh
set -eu
PATH="/usr/local/bin:$PATH"
export PATH

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_REPOSITORY_URL="${GITHUB_REPOSITORY_URL:-https://github.com/mho747/wardrobe.git}"

fail() { printf '%s\n' "$*" >&2; exit 1; }

cd "$ROOT"
test -f .env || fail 'Missing .env. Refusing update.'
test -z "$(git status --porcelain)" || fail 'Refusing update: the deployment checkout has uncommitted changes.'
test "${1:-}" = '--approved-sensitive' || fail 'Refusing update without --approved-sensitive after an explicit human approval.'
backup_container_name="$(awk -F= '$1 == "WARDROBE_BACKUP_CONTAINER_NAME" { print substr($0, index($0, "=") + 1); exit }' .env)"
backup_container_name="${backup_container_name:-wardrobe-backup}"

git remote get-url origin >/dev/null 2>&1 || git remote add origin "$GITHUB_REPOSITORY_URL"
git fetch --prune origin "$GITHUB_BRANCH"
previous_revision="$(git rev-parse HEAD)"
candidate_revision="$(git rev-parse "origin/$GITHUB_BRANCH")"
if [ -n "${WARDROBE_TEST_CANDIDATE_REVISION:-}" ]; then
  [ "${WARDROBE_ROLLBACK_TEST:-0}" = '1' ] || fail 'Refusing a non-GitHub candidate outside the isolated rollback test.'
  case "${WARDROBE_BASE_PATH:-}" in
    /volume1/docker/wardrobe/candidates/rollback-test-*) ;;
    *) fail 'Refusing a non-GitHub candidate outside the isolated rollback-test path.' ;;
  esac
  candidate_revision="$(git rev-parse --verify "${WARDROBE_TEST_CANDIDATE_REVISION}^{commit}")"
fi

if [ "$previous_revision" = "$candidate_revision" ]; then
  printf 'No GitHub update is available. Current revision: %s\n' "$previous_revision"
  exit 0
fi

ALLOW_SENSITIVE_CANDIDATE=1 ./scripts/test-update.sh

if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
  fail 'Docker Compose is not installed on this Synology.'
fi

docker exec -e WARDROBE_BACKUP_ONCE=1 "$backup_container_name" /bin/sh /usr/local/bin/wardrobe-backup

rollback() {
  printf 'Update failed; restoring verified revision %s.\n' "$previous_revision" >&2
  git reset --hard "$previous_revision"
  if ! ./scripts/deploy-synology.sh; then
    printf '%s\n' 'CRITICAL: automatic rollback could not be verified. Leave the service unchanged and inspect the deployment logs.' >&2
    exit 2
  fi
  printf 'Rollback verified at revision %s.\n' "$previous_revision" >&2
  exit 1
}

git merge --ff-only "$candidate_revision" || fail 'Refusing update because the GitHub update is not a safe fast-forward.'

if ! ./scripts/deploy-synology.sh; then
  rollback
fi

printf 'Update deployed and verified at revision %s.\n' "$candidate_revision"
