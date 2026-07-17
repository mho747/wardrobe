#!/bin/sh
set -eu
PATH="/usr/local/bin:$PATH"
export PATH

BASE='/volume1/docker/wardrobe'
REPOSITORY="$BASE/repository"
REFERENCE='/volume1/homes/Martijn/wardrobe-model-reference.png'
GITHUB_REPOSITORY_URL='https://github.com/mho747/wardrobe.git'

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

umask 077
IFS= read -r OPENAI_API_KEY || fail 'No OpenAI API key was received through standard input.'
test -n "$OPENAI_API_KEY" || fail 'The OpenAI API key is empty.'
test -f "$REFERENCE" || fail 'The verified model-reference PNG is missing from the temporary transfer path.'
trap 'rm -f "$REFERENCE"' EXIT HUP INT TERM

for target in "$BASE" "$REPOSITORY" "$BASE/data" "$BASE/backups" "$BASE/update-state" "$BASE/candidates"; do
  test ! -e "$target" || fail "Refusing installation: target already exists: $target"
done

mkdir -p "$BASE"
git clone --branch main "$GITHUB_REPOSITORY_URL" "$REPOSITORY" || fail 'Git checkout from GitHub failed.'
test "$(git -C "$REPOSITORY" remote get-url origin)" = "$GITHUB_REPOSITORY_URL" || fail 'GitHub is not the configured deployment source.'
git -C "$REPOSITORY" fetch --prune origin main || fail 'The GitHub source check failed.'
test "$(git -C "$REPOSITORY" rev-parse HEAD)" = "$(git -C "$REPOSITORY" rev-parse origin/main)" || fail 'The cloned revision is not the current GitHub main revision.'

install -d -o 1000 -g 1000 -m 0700 "$BASE/data" "$BASE/backups" "$BASE/update-state" "$BASE/candidates"
install -o 1000 -g 1000 -m 0600 "$REFERENCE" "$BASE/data/model-reference.png"

{
  printf 'OPENAI_API_KEY=%s\n' "$OPENAI_API_KEY"
  grep -v '^OPENAI_API_KEY=' "$REPOSITORY/.env.example" | sed \
    -e 's|^WARDROBE_BIND_ADDRESS=.*|WARDROBE_BIND_ADDRESS=192.168.192.150|'
} > "$REPOSITORY/.env"
chmod 600 "$REPOSITORY/.env"

if ! "$REPOSITORY/scripts/deploy-synology.sh"; then
  exit 1
fi

printf 'Installation verified. revision=%s url=http://192.168.192.150:4173/\n' "$(git -C "$REPOSITORY" rev-parse HEAD)"
