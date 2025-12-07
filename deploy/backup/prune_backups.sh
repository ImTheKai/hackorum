#!/usr/bin/env bash
set -euo pipefail

# Prune old base backups and WAL archives stored locally.
# Adjust RETAIN count as needed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RETAIN="${RETAIN:-3}"

echo "Pruning base backups, keeping ${RETAIN} most recent..."
docker compose -f docker-compose.yml exec -T db bash -lc '
  cd /backups || exit 0
  ls -1dt base-* 2>/dev/null | tail -n +$((RETAIN+1)) | xargs -r rm -rf
'

echo "Pruning WAL files older than 14 days..."
docker compose -f docker-compose.yml exec -T db bash -lc 'find /var/lib/postgresql/wal-archive -type f -mtime +14 -print -delete'

echo "Prune complete."
