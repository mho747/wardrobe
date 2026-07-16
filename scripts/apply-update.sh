#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_REPOSITORY_URL="${GITHUB_REPOSITORY_URL:-https://github.com/tandpfun/wardrobe.git}"

fail() { printf '%s\n' "$*" >&2; exit 1; }

cd "$ROOT"
test -f .env || fail 'Missing .env. Refusing update.'
test -z "$(git status --porcelain)" || fail 'Refusing update: the deployment checkout has uncommitted changes.'
test "${1:-}" = '--approved-sensitive' || fail 'Refusing update without --approved-sensitive after an explicit human approval.'

git remote get-url origin >/dev/null 2>&1 || git remote add origin "$GITHUB_REPOSITORY_URL"
git fetch --prune origin "$GITHUB_BRANCH"
previous_revision="$(git rev-parse HEAD)"
candidate_revision="$(git rev-parse "origin/$GITHUB_BRANCH")"

if [ "$previous_revision" = "$candidate_revision" ]; then
  printf 'No GitHub update is available. Current revision: %s\n' "$previous_revision"
  exit 0
fi

ALLOW_SENSITIVE_CANDIDATE=1 ./scripts/test-update.sh

if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
  fail 'Docker Compose is not installed on this Synology.'
fi

if docker compose version >/dev/null 2>&1; then
  docker compose run --rm --no-deps -e WARDROBE_BACKUP_ONCE=1 wardrobe-backup
else
  docker-compose run --rm --no-deps -e WARDROBE_BACKUP_ONCE=1 wardrobe-backup
fi

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

if ! git merge --ff-only "$candidate_revision"; then
  fail 'Refusing update because the candidate is not a fast-forward Git update.'
fi

if ! ./scripts/deploy-synology.sh; then
  rollback
fi

printf 'Update deployed and verified at revision %s.\n' "$candidate_revision"
