#!/usr/bin/env bash
set -euo pipefail

# Create monthly SQL dumps (compressed) into the /dumps volume.
# Layout (avoids circular dependencies between public and private dumps):
#   /dumps/public/schema-YYYY-MM.sql.gz       Full schema (all tables), no data.
#   /dumps/public/public-data-YYYY-MM.sql.gz  Data only, excluding private tables.
#   /dumps/private/private-data-YYYY-MM.sql.gz  Data only, only private tables.
#
# Import order: schema -> public-data -> private-data.

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
  EXCLUDE_ARGS+=("--exclude-table-data=public.${table}")
  INCLUDE_ARGS+=("--table=public.${table}")
done

EXCLUDE_ARGS_STR="$(printf ' %q' "${EXCLUDE_ARGS[@]}")"
INCLUDE_ARGS_STR="$(printf ' %q' "${INCLUDE_ARGS[@]}")"

echo "Writing dumps for ${STAMP} to /dumps/public and /dumps/private..."

docker compose -f docker-compose.yml exec -T db bash -lc \
  "mkdir -p /dumps/public /dumps/private \
  && pg_dump -U \${POSTGRES_USER:-postgres} -d \${POSTGRES_DB:-hackorum} \
     --format=plain --schema-only --no-owner --no-privileges \
     | gzip -9 > /dumps/public/schema-${STAMP}.sql.gz \
  && pg_dump -U \${POSTGRES_USER:-postgres} -d \${POSTGRES_DB:-hackorum} \
     --format=plain --data-only --no-owner --no-privileges${EXCLUDE_ARGS_STR} \
     | gzip -9 > /dumps/public/public-data-${STAMP}.sql.gz \
  && pg_dump -U \${POSTGRES_USER:-postgres} -d \${POSTGRES_DB:-hackorum} \
     --format=plain --data-only --no-owner --no-privileges${INCLUDE_ARGS_STR} \
     | gzip -9 > /dumps/private/private-data-${STAMP}.sql.gz"

echo "Done."
