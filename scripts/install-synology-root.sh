#!/bin/sh
set -eu
PATH="/usr/local/bin:$PATH"
export PATH

BASE='/volume1/docker/wardrobe'
REPOSITORY="$BASE/repository"
BUNDLE='/volume1/homes/Martijn/wardrobe-deployment.bundle'
REFERENCE='/volume1/homes/Martijn/model-reference.png'
REPORT='/volume1/homes/Martijn/wardrobe-install-result.txt'
UPSTREAM_REVISION='f44006cce7e4779e595a35b25fbbc8dabc68d7e4'

fail() {
  printf 'FAILED\n%s\n' "$1" > "$REPORT"
  exit 1
}

umask 077
IFS= read -r OPENAI_API_KEY || fail 'No OpenAI API key was received through standard input.'
test -n "$OPENAI_API_KEY" || fail 'The OpenAI API key is empty.'
test -f "$BUNDLE" || fail 'The verified Wardrobe Git-bundle is missing from the temporary transfer path.'
test -f "$REFERENCE" || fail 'The verified model-reference PNG is missing from the temporary transfer path.'

for target in "$BASE" "$REPOSITORY" "$BASE/data" "$BASE/backups" "$BASE/update-state" "$BASE/candidates"; do
  test ! -e "$target" || fail "Refusing installation: target already exists: $target"
done

mkdir -p "$BASE"
git clone --branch main "$BUNDLE" "$REPOSITORY" || fail 'Git checkout from the verified local bundle failed.'
git -C "$REPOSITORY" remote set-url origin 'https://github.com/tandpfun/wardrobe.git'
git -C "$REPOSITORY" fetch origin main || fail 'The read-only GitHub upstream check failed.'

install -d -o 1000 -g 1000 -m 0700 "$BASE/data" "$BASE/backups" "$BASE/update-state" "$BASE/candidates"
install -o 1000 -g 1000 -m 0600 "$REFERENCE" "$BASE/data/model-reference.png"

{
  printf 'OPENAI_API_KEY=%s\n' "$OPENAI_API_KEY"
  grep -v '^OPENAI_API_KEY=' "$REPOSITORY/.env.example" | sed \
    -e 's|^WARDROBE_BIND_ADDRESS=.*|WARDROBE_BIND_ADDRESS=192.168.192.150|' \
    -e "s|^WARDROBE_UPSTREAM_REVISION=.*|WARDROBE_UPSTREAM_REVISION=$UPSTREAM_REVISION|"
} > "$REPOSITORY/.env"
chmod 600 "$REPOSITORY/.env"

if ! "$REPOSITORY/scripts/deploy-synology.sh"; then
  printf 'FAILED\nThe deployment verification script failed. The new Wardrobe containers may exist; inspect its output before any cleanup.\n' > "$REPORT"
  exit 1
fi

rm -f "$BUNDLE" "$REFERENCE"
printf 'SUCCESS\nrevision=%s\nupstream=%s\nurl=http://192.168.192.150:4173/\n' "$(git -C "$REPOSITORY" rev-parse HEAD)" "$UPSTREAM_REVISION" > "$REPORT"
