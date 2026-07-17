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
      "$ROOT"/.env.key-update.*|"$ROOT"/.env.rollback.*)
        rm -f "$file"
        ;;
    esac
  done
}
trap cleanup EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'Run this script with sudo on the Synology.'
[ "$ROOT" = /volume1/docker/wardrobe/repository ] || fail 'Refusing to change a key outside the Wardrobe production checkout.'
[ -r "$TTY" ] && [ -w "$TTY" ] || fail 'An interactive terminal is required for hidden key entry.'
test -f "$ENV_FILE" || fail 'Missing Wardrobe .env.'
test "$(git -C "$ROOT" remote get-url origin)" = 'https://github.com/mho747/wardrobe.git' || fail 'Unexpected GitHub remote.'

printf '%s' 'OpenAI API-key (verborgen): ' > "$TTY"
stty -echo < "$TTY"
IFS= read -r api_key < "$TTY"
stty echo < "$TTY"
printf '\n' > "$TTY"
case "$api_key" in
  sk-??????????????????*) ;;
  *) fail 'The supplied OpenAI API key has an unexpected format.' ;;
esac

umask 077
replacement="$(mktemp "$ROOT/.env.key-update.XXXXXX")"
rollback="$(mktemp "$ROOT/.env.rollback.XXXXXX")"
cp "$ENV_FILE" "$rollback"
found=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    OPENAI_API_KEY=*)
      printf 'OPENAI_API_KEY=%s\n' "$api_key" >> "$replacement"
      found=1
      ;;
    *) printf '%s\n' "$line" >> "$replacement" ;;
  esac
done < "$ENV_FILE"
[ "$found" -eq 1 ] || printf 'OPENAI_API_KEY=%s\n' "$api_key" >> "$replacement"
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
  fail 'Wardrobe could not be recreated after the key update.'
fi

attempts=0
health=
while [ "$attempts" -lt 20 ]; do
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' wardrobe 2>/dev/null || true)"
  [ "$health" = healthy ] && break
  [ "$health" = unhealthy ] && { restore_previous_key || true; fail 'Wardrobe became unhealthy after the key update.'; }
  attempts=$((attempts + 1))
  sleep 2
done
[ "$health" = healthy ] || { restore_previous_key || true; fail 'Wardrobe did not become healthy within 40 seconds.'; }

if ! docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' wardrobe | grep -q '^OPENAI_API_KEY=sk-'; then
  restore_previous_key || true
  fail 'Wardrobe did not receive a valid OpenAI key.'
fi

rm -f "$rollback"
rollback=
printf '%s\n' 'OpenAI API key stored. Wardrobe is healthy; no OpenAI request was made.'
