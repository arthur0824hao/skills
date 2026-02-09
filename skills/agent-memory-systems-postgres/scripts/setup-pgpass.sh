#!/usr/bin/env bash
set -euo pipefail

echo "PGHOST (default: localhost): "
read -r PGHOST_IN || true
PGHOST_IN="${PGHOST_IN:-localhost}"

echo "PGPORT (default: 5432): "
read -r PGPORT_IN || true
PGPORT_IN="${PGPORT_IN:-5432}"

echo "PGDATABASE (default: agent_memory): "
read -r PGDATABASE_IN || true
PGDATABASE_IN="${PGDATABASE_IN:-agent_memory}"

echo "PGUSER (default: postgres): "
read -r PGUSER_IN || true
PGUSER_IN="${PGUSER_IN:-postgres}"

echo -n "Password: "
stty -echo
read -r PGPASS_IN
stty echo
echo

if [ -z "$PGPASS_IN" ]; then
  echo "Password cannot be empty" >&2
  exit 1
fi

pgpass_path="$HOME/.pgpass"
esc_pass="${PGPASS_IN//\\/\\\\}"
esc_pass="${esc_pass//:/\\:}"

printf '%s:%s:%s:%s:%s\n' "$PGHOST_IN" "$PGPORT_IN" "$PGDATABASE_IN" "$PGUSER_IN" "$esc_pass" > "$pgpass_path"
chmod 0600 "$pgpass_path"

echo "Wrote $pgpass_path (mode 0600)"
