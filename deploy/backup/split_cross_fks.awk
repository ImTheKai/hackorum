# Filters a legacy pg_dump SQL stream (from the "public" dump produced by
# run_monthly_dumps.sh before the 2026-06 schema split) so it can be loaded
# without conflicting with the companion private-schema dump.
#
# Two kinds of cross-dump bleed are handled:
#   1. CREATE SEQUENCE / setval for tables listed in private_tables.txt:
#      pg_dump emits these into the public dump as orphan sequences even
#      when the owning table is excluded. We drop them (private-schema
#      dump recreates them).
#   2. FOREIGN KEY constraints from public tables that reference private
#      tables: these fail in the public load because the referenced table
#      does not exist yet. We extract them into `fkfile` so the caller can
#      reapply them after the private-schema load.
#
# Usage:
#   awk -v t='users|teams|...' -v fkfile=/tmp/cross_fks.sql -f split_cross_fks.awk dump.sql
# stdout receives the filtered dump; fkfile receives the extracted FKs.

BEGIN {
  if (fkfile == "") { print "split_cross_fks.awk: fkfile not set" > "/dev/stderr"; exit 2 }
  if (t == "")      { print "split_cross_fks.awk: t (private-table regex) not set" > "/dev/stderr"; exit 2 }
  seq_re    = "^CREATE SEQUENCE public[.](" t ")_id_seq([^a-z_]|$)"
  setval_re = "^SELECT pg_catalog[.]setval[(]'public[.](" t ")_id_seq'"
  fk_re     = "REFERENCES public[.](" t ")[(]"
  printf "" > fkfile
  in_seq = 0
  state  = 0
}

# 1a. Drop the body of a CREATE SEQUENCE block for a private table.
in_seq {
  if ($0 ~ /;[[:space:]]*$/) in_seq = 0
  next
}

# 1b. Detect the start of a CREATE SEQUENCE block for a private table.
$0 ~ seq_re {
  if ($0 ~ /;[[:space:]]*$/) { next }
  in_seq = 1
  next
}

# 1c. Drop setval calls for private sequences.
$0 ~ setval_re { next }

# 2a. We just saw an ALTER TABLE ONLY line; decide what to do with the
#     ADD CONSTRAINT line that follows. Cross-FKs are rewritten with
#     NOT VALID so the constraint can be reapplied even when the referenced
#     private table has no data in this environment.
state == 1 {
  if ($0 ~ fk_re) {
    line = $0
    sub(/;[[:space:]]*$/, " NOT VALID;", line)
    print prev > fkfile
    print line > fkfile
  } else {
    print prev
    print $0
  }
  state = 0
  next
}

# 2b. Detect a potential cross-FK statement.
/^ALTER TABLE ONLY / {
  prev = $0
  state = 1
  next
}

# Everything else passes through.
{ print }

END {
  if (state == 1) print prev
  close(fkfile)
}
