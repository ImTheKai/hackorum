#!/usr/bin/env bash
set -euo pipefail

# Run a compressed base backup and keep WAL archives locally.
# Requires docker compose and the db service running.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STAMP="$(date +%F_%H%M)"
TARGET_DIR="/backups/base-${STAMP}"

echo "Creating base backup at ${TARGET_DIR}..."
docker compose -f docker-compose.yml exec -T db bash -lc "mkdir -p ${TARGET_DIR}"
docker compose -f docker-compose.yml exec -T db bash -lc "pg_basebackup -D ${TARGET_DIR} -F tar -X stream -z -P"

echo "Base backup complete."
