#!/bin/bash
# Write-side control for the two ordered-scan patches.
#
# Both patches touch only the scan path, so every figure here is expected
# to be flat between A and C.  The purpose is to catch an unexpected
# connection, not to find a win.
#
#   A  both GUCs off      baseline
#   C  both GUCs on       final
#
# DML is measured with EXPLAIN (ANALYZE, BUFFERS, WAL), which reports
# time, buffers and WAL records/bytes directly.  CREATE INDEX, CIC and
# VACUUM are measured by LSN delta and clock, since EXPLAIN does not
# apply to them.
set -u
PSQL="/home/claude/pg20/bin/psql -h /tmp/pgsock20 -p 5455 -X t20"
RUNS=2

guc() { case "$1" in
    A) echo "SET rum.ordered_candidate_pruning=off; SET rum.trgm_rank_from_match=off;" ;;
    C) echo "SET rum.ordered_candidate_pruning=on;  SET rum.trgm_rank_from_match=on;"  ;;
esac; }

median() { sort -n | awk '{a[NR]=$1} END {print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

# $1 mode, $2 label, $3 rows to insert into the fixture, $4 statement
dml() {
    local mode=$1 label=$2 src=$3 stmt=$4
    local t_l="" w_l="" b_l=""
    for i in $(seq 1 $RUNS); do
        out=$(su postgres -c "$PSQL" <<EOF 2>&1
$(guc $mode)
DROP TABLE IF EXISTS w_bench;
CREATE TABLE w_bench AS SELECT id, body FROM $src LIMIT 2000;
CREATE INDEX w_bench_rum ON w_bench USING rum (body rum_trgm_ops);
VACUUM ANALYZE w_bench;
CHECKPOINT;
EXPLAIN (ANALYZE, BUFFERS, WAL, COSTS OFF) $stmt
EOF
)
        t_l+="$(echo "$out" | grep -oE 'Execution Time: [0-9.]+' | awk '{print $3}')"$'\n'
        w_l+="$(echo "$out" | grep -oE 'WAL: records=[0-9]+ fpi=[0-9]+ bytes=[0-9]+' | head -1 | grep -oE 'bytes=[0-9]+' | cut -d= -f2)"$'\n'
        b_l+="$(echo "$out" | grep -oE 'shared dirtied=[0-9]+' | head -1 | cut -d= -f2)"$'\n'
    done
    printf "%-22s %-4s %12s %14s %12s\n" "$label" "$mode" \
        "$(echo "$t_l" | grep -v '^$' | median)" \
        "$(echo "$w_l" | grep -v '^$' | median)" \
        "$(echo "$b_l" | grep -v '^$' | median)"
}

# $1 mode, $2 label, $3 statements (no EXPLAIN), $4 relation to size afterwards
timed() {
    local mode=$1 label=$2 stmt=$3 rel=$4
    local t_l="" w_l="" sz=""
    for i in $(seq 1 $RUNS); do
        out=$(su postgres -c "$PSQL" <<EOF 2>&1
$(guc $mode)
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
    printf "%-22s %-4s %12s %14s %12s\n" "$label" "$mode" \
        "$(echo "$t_l" | grep -v '^$' | median)" \
        "$(echo "$w_l" | grep -v '^$' | median)" "$sz"
}

printf "%-22s %-4s %12s %14s %12s\n" operation mode "median ms" "WAL bytes" "size/dirtied"
printf -- "-------------------------------------------------------------------\n"
if [ "${1:-all}" = dml ] || [ "${1:-all}" = all ]; then
for mode in A C; do
    dml   $mode "INSERT 500"   msgs  "INSERT INTO w_bench SELECT id + 1000000, body FROM msgs LIMIT 500;"
    dml   $mode "UPDATE 200"  msgs  "UPDATE w_bench SET body = body || ' zz' WHERE id % 10 = 0;"
    dml   $mode "DELETE 200"  msgs  "DELETE FROM w_bench WHERE id % 10 = 0;"
done
fi
if [ "${1:-all}" = ddl ] || [ "${1:-all}" = all ]; then
for mode in A C; do
    timed $mode "CREATE INDEX"      "CREATE INDEX w_bench_rum ON w_bench USING rum (body rum_trgm_ops);" w_bench_rum
    timed $mode "CREATE INDEX CONC." "CREATE INDEX CONCURRENTLY w_bench_rum ON w_bench USING rum (body rum_trgm_ops);" w_bench_rum
    timed $mode "DELETE+VACUUM" "DELETE FROM w_bench WHERE id % 10 = 0; VACUUM w_bench;" w_bench_rum
done
fi
su postgres -c "$PSQL -c 'DROP TABLE IF EXISTS w_bench'" >/dev/null 2>&1
