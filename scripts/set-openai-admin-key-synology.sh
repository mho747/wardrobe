#!/bin/sh
set -eu
PATH="/usr/local/bin:$PATH"
export PATH

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"
TTY=/dev/tty
replacement=
rollback=

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

cleanup() {
  stty echo < "$TTY" >/dev/null 2>&1 || true
  for file in "${replacement:-}" "${rollback:-}"; do
    case "$file" in
      "$ROOT"/.env.admin-key-update.*|"$ROOT"/.env.rollback.*) rm -f "$file" ;;
    esac
  done
}
trap cleanup EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'Run this script with sudo on the Synology.'
[ "$ROOT" = /volume1/docker/wardrobe/repository ] || fail 'Refusing to change a key outside the Wardrobe production checkout.'
[ -r "$TTY" ] && [ -w "$TTY" ] || fail 'An interactive terminal is required for hidden key entry.'
test -f "$ENV_FILE" || fail 'Missing Wardrobe .env.'
test "$(git -C "$ROOT" remote get-url origin)" = 'https://github.com/mho747/wardrobe.git' || fail 'Unexpected GitHub remote.'

printf '%s' 'OpenAI Admin API-key voor kosten (verborgen): ' > "$TTY"
stty -echo < "$TTY"
IFS= read -r admin_key < "$TTY"
stty echo < "$TTY"
printf '\n' > "$TTY"
test -n "$admin_key" || fail 'The OpenAI Admin API key is empty.'

umask 077
replacement="$(mktemp "$ROOT/.env.admin-key-update.XXXXXX")"
rollback="$(mktemp "$ROOT/.env.rollback.XXXXXX")"
cp "$ENV_FILE" "$rollback"
found=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    OPENAI_ADMIN_API_KEY=*)
      printf 'OPENAI_ADMIN_API_KEY=%s\n' "$admin_key" >> "$replacement"
      found=1
      ;;
    *) printf '%s\n' "$line" >> "$replacement" ;;
  esac
done < "$ENV_FILE"
[ "$found" -eq 1 ] || printf 'OPENAI_ADMIN_API_KEY=%s\n' "$admin_key" >> "$replacement"
chmod 600 "$replacement"
mv "$replacement" "$ENV_FILE"
replacement=

restore_previous_key() {
  mv "$rollback" "$ENV_FILE"
  rollback=
  docker compose -f "$ROOT/compose.yaml" up -d --no-deps --force-recreate wardrobe >/dev/null
}

if ! docker compose -f "$ROOT/compose.yaml" up -d --no-deps --force-recreate wardrobe; then
  restore_previous_key || true
  fail 'Wardrobe could not be recreated after the Admin key update.'
fi

attempts=0
health=
while [ "$attempts" -lt 20 ]; do
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' wardrobe 2>/dev/null || true)"
  [ "$health" = healthy ] && break
  [ "$health" = unhealthy ] && { restore_previous_key || true; fail 'Wardrobe became unhealthy after the Admin key update.'; }
  attempts=$((attempts + 1))
  sleep 2
done
[ "$health" = healthy ] || { restore_previous_key || true; fail 'Wardrobe did not become healthy within 40 seconds.'; }

if ! docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' wardrobe | grep -q '^OPENAI_ADMIN_API_KEY='; then
  restore_previous_key || true
  fail 'Wardrobe did not receive the OpenAI Admin key.'
fi

rm -f "$rollback"
rollback=
printf '%s\n' 'OpenAI Admin key stored. Wardrobe is healthy; no OpenAI request was made.'
