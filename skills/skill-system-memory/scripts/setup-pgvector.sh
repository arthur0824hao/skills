#!/usr/bin/env bash
set -euo pipefail

# Linux/macOS helper: attempts to enable pgvector.
# Installing pgvector varies by distro and packaging; this script does not try to install system packages.

if ! command -v psql >/dev/null 2>&1; then
  echo "psql not found" >&2
  exit 1
fi

psql -w -h localhost -p 5432 -U postgres -d agent_memory -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1 || {
  echo "CREATE EXTENSION vector failed. Install pgvector for your Postgres distribution." >&2
  exit 0
}

echo "pgvector extension enabled."
exit 0
