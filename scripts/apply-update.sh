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
previous_upstream_revision="$(awk -F= '$1 == "WARDROBE_UPSTREAM_REVISION" { print substr($0, index($0, "=") + 1); exit }' .env)"
test -n "$previous_upstream_revision" || fail 'WARDROBE_UPSTREAM_REVISION is missing from .env.'
candidate_revision="$(git rev-parse "origin/$GITHUB_BRANCH")"

if [ "$previous_upstream_revision" = "$candidate_revision" ]; then
  printf 'No GitHub update is available. Current upstream revision: %s\n' "$previous_upstream_revision"
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
  revision_file=".env.rollback.$$"
  awk -v revision="$previous_upstream_revision" '
    /^WARDROBE_UPSTREAM_REVISION=/ { print "WARDROBE_UPSTREAM_REVISION=" revision; found=1; next }
    { print }
    END { if (!found) print "WARDROBE_UPSTREAM_REVISION=" revision }
  ' .env > "$revision_file"
  mv "$revision_file" .env
  if ! ./scripts/deploy-synology.sh; then
    printf '%s\n' 'CRITICAL: automatic rollback could not be verified. Leave the service unchanged and inspect the deployment logs.' >&2
    exit 2
  fi
  printf 'Rollback verified at revision %s.\n' "$previous_revision" >&2
  exit 1
}

if ! git merge --no-edit "$candidate_revision"; then
  fail 'Refusing update because the GitHub update cannot merge cleanly with the protected deployment checkout.'
fi

revision_file=".env.upstream.$$"
awk -v revision="$candidate_revision" '
  /^WARDROBE_UPSTREAM_REVISION=/ { print "WARDROBE_UPSTREAM_REVISION=" revision; found=1; next }
  { print }
  END { if (!found) print "WARDROBE_UPSTREAM_REVISION=" revision }
' .env > "$revision_file"
mv "$revision_file" .env
chmod 600 .env

if ! ./scripts/deploy-synology.sh; then
  rollback
fi

printf 'Update deployed and verified at revision %s.\n' "$candidate_revision"
