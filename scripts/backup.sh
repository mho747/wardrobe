#!/bin/sh
set -eu

SOURCE_DIR="${SOURCE_DIR:-/source}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-86400}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

case "$BACKUP_INTERVAL_SECONDS" in
  ''|*[!0-9]*) echo 'BACKUP_INTERVAL_SECONDS must be a positive integer.' >&2; exit 64 ;;
esac
case "$BACKUP_RETENTION_DAYS" in
  ''|*[!0-9]*) echo 'BACKUP_RETENTION_DAYS must be a non-negative integer.' >&2; exit 64 ;;
esac

umask 077

backup_once() {
  test -d "$SOURCE_DIR"
  mkdir -p "$BACKUP_DIR"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="$BACKUP_DIR/wardrobe-$stamp.tar.gz"
  temporary="$archive.partial"

  rm -f "$temporary"
  tar -C "$SOURCE_DIR" -czf "$temporary" .
  tar -tzf "$temporary" >/dev/null
  mv "$temporary" "$archive"
  printf '%s %s\n' "$stamp" "$(basename "$archive")" > "$BACKUP_DIR/.last-success"

  if [ "$BACKUP_RETENTION_DAYS" -gt 0 ]; then
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'wardrobe-*.tar.gz' -mtime "+$BACKUP_RETENTION_DAYS" -delete
  fi
}

backup_once

if [ "${WARDROBE_BACKUP_ONCE:-0}" = '1' ]; then
  exit 0
fi

while :; do
  sleep "$BACKUP_INTERVAL_SECONDS"
  backup_once
done
