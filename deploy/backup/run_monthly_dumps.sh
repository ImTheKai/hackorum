#!/usr/bin/env bash
set -euo pipefail

# Create monthly public/private SQL dumps (compressed) into the /dumps volume.
# Public dump: full schema + data, excluding private tables.
# Private dump: data-only, only private tables.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TABLES_FILE="${TABLES_FILE:-${ROOT}/backup/private_tables.txt}"
STAMP="$(date +%Y-%m)"

if [[ ! -f "${TABLES_FILE}" ]]; then
  echo "Private tables file not found: ${TABLES_FILE}" >&2
  exit 1
fi

readarray -t PRIVATE_TABLES < <(grep -E '^[a-z0-9_]+$' "${TABLES_FILE}")

if [[ ${#PRIVATE_TABLES[@]} -eq 0 ]]; then
  echo "No private tables found in ${TABLES_FILE}" >&2
  exit 1
fi

EXCLUDE_ARGS=()
INCLUDE_ARGS=()
for table in "${PRIVATE_TABLES[@]}"; do
  EXCLUDE_ARGS+=("--exclude-table=public.${table}")
  INCLUDE_ARGS+=("--table=public.${table}")
done

EXCLUDE_ARGS_STR="$(printf ' %q' "${EXCLUDE_ARGS[@]}")"
INCLUDE_ARGS_STR="$(printf ' %q' "${INCLUDE_ARGS[@]}")"

echo "Writing dumps for ${STAMP} to /dumps/public and /dumps/private..."

docker compose -f docker-compose.yml exec -T db bash -lc \
  "mkdir -p /dumps/public /dumps/private \
  && pg_dump -U \${POSTGRES_USER:-postgres} -d \${POSTGRES_DB:-hackorum} \
     --format=plain --no-owner --no-privileges${EXCLUDE_ARGS_STR} \
     | gzip -9 > /dumps/public/public-${STAMP}.sql.gz \
  && pg_dump -U \${POSTGRES_USER:-postgres} -d \${POSTGRES_DB:-hackorum} \
     --format=plain --data-only --no-owner --no-privileges${INCLUDE_ARGS_STR} \
     | gzip -9 > /dumps/private/private-${STAMP}.sql.gz"

echo "Done."
