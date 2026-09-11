#!/bin/bash
# Write-side control for the two ordered-scan patches.
#
# The branch touches only the scan path, so the purpose is to catch an
# unexpected connection to the write side, not to find a win.
#
# There is no run-time switch, so this measures the branch only.
# For the baseline, run the same script against an unpatched RUM on the
# same corpus and compare.
#
# DML is measured with EXPLAIN (ANALYZE, BUFFERS, WAL), which reports
# time, buffers and WAL records/bytes directly.  CREATE INDEX, CIC and
# VACUUM are measured by LSN delta and clock, since EXPLAIN does not
# apply to them.
set -u
PSQL="/home/claude/pg20/bin/psql -h /tmp/pgsock20 -p 5455 -X t20"
RUNS=2

# $1 label, $2 statements (no EXPLAIN), $3 relation to size afterwards
timed() {
    local label=$1 stmt=$2 rel=$3
    local t_l="" w_l="" sz=""
    for i in $(seq 1 $RUNS); do
        out=$(su postgres -c "$PSQL" <<EOF 2>&1
DROP TABLE IF EXISTS w_bench;
CREATE TABLE w_bench AS SELECT id, body FROM msgs LIMIT 2000;
$( [ "$label" = "CREATE INDEX" ] || [ "$label" = "CREATE INDEX CONC." ] || \
   echo "CREATE INDEX w_bench_rum ON w_bench USING rum (body rum_trgm_ops);" )
CHECKPOINT;
CREATE TEMP TABLE mark AS SELECT pg_current_wal_lsn() l, clock_timestamp() t;
$stmt
SELECT round(extract(epoch from (clock_timestamp()-(SELECT t FROM mark)))*1000)::text || ' MS';
SELECT (pg_current_wal_lsn()-(SELECT l FROM mark))::text || ' WAL';
SELECT pg_relation_size('$rel')::text || ' SZ';
DROP TABLE mark;
EOF
)
        t_l+="$(echo "$out" | grep -oE '[0-9]+ MS' | awk '{print $1}')"$'\n'
        w_l+="$(echo "$out" | grep -oE '[0-9]+ WAL' | awk '{print $1}')"$'\n'
        sz=$(echo "$out" | grep -oE '[0-9]+ SZ' | awk '{print $1}')
    done
    printf "%-22s %12s %14s %12s\n" "$label" \
        "$(echo "$t_l" | grep -v '^$' | median)" \
        "$(echo "$w_l" | grep -v '^$' | median)" "$sz"
}

printf "%-22s %12s %14s %12s\n" operation "median ms" "WAL bytes" "size/dirtied"
printf -- "-------------------------------------------------------------------\n"
if [ "${1:-all}" = dml ] || [ "${1:-all}" = all ]; then
    dml   "INSERT 500"   msgs  "INSERT INTO w_bench SELECT id + 1000000, body FROM msgs LIMIT 500;"
    dml   "UPDATE 200"  msgs  "UPDATE w_bench SET body = body || ' zz' WHERE id % 10 = 0;"
    dml   "DELETE 200"  msgs  "DELETE FROM w_bench WHERE id % 10 = 0;"
fi
if [ "${1:-all}" = ddl ] || [ "${1:-all}" = all ]; then
    timed "CREATE INDEX"      "CREATE INDEX w_bench_rum ON w_bench USING rum (body rum_trgm_ops);" w_bench_rum
    timed "CREATE INDEX CONC." "CREATE INDEX CONCURRENTLY w_bench_rum ON w_bench USING rum (body rum_trgm_ops);" w_bench_rum
    timed "DELETE+VACUUM" "DELETE FROM w_bench WHERE id % 10 = 0; VACUUM w_bench;" w_bench_rum
fi
su postgres -c "$PSQL -c 'DROP TABLE IF EXISTS w_bench'" >/dev/null 2>&1
