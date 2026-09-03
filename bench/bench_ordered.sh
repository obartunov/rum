#!/bin/bash
# Benchmark for the two ordered-trigram patches, measuring each separately.
#
#   A  baseline                    both GUCs off
#   B  + candidate-aware ordered   rum.ordered_candidate_pruning on
#   C  + rank reuse                B + rum.trgm_rank_from_match on
#
# Warm median of N runs per point.
#
# Usage:
#   bench_ordered.sh timings
#   bench_ordered.sh controls
#   bench_ordered.sh writes     write-side control: expect no difference
set -u
PSQL="/home/claude/pg20/bin/psql -h /tmp/pgsock20 -p 5455 -X t20"
RUNS=5
Q="I am attaching the patch for the current master branch and the test results"

run_as() { su postgres -c "$PSQL $*"; }

guc_for() {
    case "$1" in
        A) echo "SET rum.ordered_candidate_pruning=off; SET rum.trgm_rank_from_match=off;" ;;
        B) echo "SET rum.ordered_candidate_pruning=on;  SET rum.trgm_rank_from_match=off;" ;;
        C) echo "SET rum.ordered_candidate_pruning=on;  SET rum.trgm_rank_from_match=on;" ;;
    esac
}

median() { sort -n | awk '{a[NR]=$1} END {print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}'; }

timings() {
    printf "%-8s %-6s %-6s %-6s %10s %10s\n" corpus t limit mode "median ms" "runs"
    for tbl in msgs big_c; do
        for t in 0.05 0.10 0.15; do
            for lim in 10 100; do
                for mode in A B C; do
                    # two warm-ups, then RUNS measured executions
                    out=$(su postgres -c "$PSQL" <<EOF 2>&1
SET max_parallel_workers_per_gather=0; SET enable_seqscan=off;
SET pg_trgm.similarity_threshold=$t;
$(guc_for $mode)
SELECT count(*) FROM (SELECT body FROM $tbl WHERE body % '$Q' ORDER BY body <-> '$Q' LIMIT $lim) x;
SELECT count(*) FROM (SELECT body FROM $tbl WHERE body % '$Q' ORDER BY body <-> '$Q' LIMIT $lim) x;
$(for i in $(seq 1 $RUNS); do
    echo "EXPLAIN (ANALYZE, COSTS OFF) SELECT body FROM $tbl WHERE body % '$Q' ORDER BY body <-> '$Q' LIMIT $lim;"
  done)
EOF
)
                    med=$(echo "$out" | grep -oE "Execution Time: [0-9.]+" | awk '{print $3}' | median)
                    printf "%-8s %-6s %-6s %-6s %10s %10s\n" "$tbl" "$t" "$lim" "$mode" "$med" "$RUNS"
                done
            done
        done
    done
}

controls() {
    echo "-- negative controls: the optimization must not engage"
    su postgres -c "$PSQL" <<'EOF' 2>&1 | grep -E "ctl "
SET enable_seqscan=off; SET max_parallel_workers_per_gather=0;
SET pg_trgm.similarity_threshold=0.15;

-- 1. different query in WHERE and ORDER BY
SET rum.ordered_candidate_pruning=off; SET rum.trgm_rank_from_match=off;
CREATE TEMP TABLE c1a AS SELECT row_number() OVER () rn, ctid tid,
       float4send((body <-> 'logical replication slot conflict')::float4) rk
FROM (SELECT ctid, body FROM big_c
      WHERE body % 'I am attaching the patch for the current master branch and the test results'
      ORDER BY body <-> 'logical replication slot conflict' LIMIT 50) s;
SET rum.ordered_candidate_pruning=on; SET rum.trgm_rank_from_match=on;
CREATE TEMP TABLE c1b AS SELECT row_number() OVER () rn, ctid tid,
       float4send((body <-> 'logical replication slot conflict')::float4) rk
FROM (SELECT ctid, body FROM big_c
      WHERE body % 'I am attaching the patch for the current master branch and the test results'
      ORDER BY body <-> 'logical replication slot conflict' LIMIT 50) s;
SELECT 'ctl different-order-by-query identical='
    || ((SELECT array_agg(tid ORDER BY rn) FROM c1a) IS NOT DISTINCT FROM (SELECT array_agg(tid ORDER BY rn) FROM c1b))
    || ' rank='
    || ((SELECT array_agg(rk ORDER BY rn) FROM c1a) IS NOT DISTINCT FROM (SELECT array_agg(rk ORDER BY rn) FROM c1b));

-- 2. tsvector ordered
SET rum.ordered_candidate_pruning=off; SET rum.trgm_rank_from_match=off;
CREATE TEMP TABLE c2a AS SELECT row_number() OVER () rn, ctid tid,
       float4send(tsv <=> to_tsquery('english','foo & bar')) rk
FROM (SELECT ctid, tsv FROM fts WHERE tsv @@ to_tsquery('english','foo & bar')
      ORDER BY tsv <=> to_tsquery('english','foo & bar') LIMIT 100) s;
SET rum.ordered_candidate_pruning=on; SET rum.trgm_rank_from_match=on;
CREATE TEMP TABLE c2b AS SELECT row_number() OVER () rn, ctid tid,
       float4send(tsv <=> to_tsquery('english','foo & bar')) rk
FROM (SELECT ctid, tsv FROM fts WHERE tsv @@ to_tsquery('english','foo & bar')
      ORDER BY tsv <=> to_tsquery('english','foo & bar') LIMIT 100) s;
SELECT 'ctl tsvector identical='
    || ((SELECT array_agg(tid ORDER BY rn) FROM c2a) IS NOT DISTINCT FROM (SELECT array_agg(tid ORDER BY rn) FROM c2b))
    || ' rank='
    || ((SELECT array_agg(rk ORDER BY rn) FROM c2a) IS NOT DISTINCT FROM (SELECT array_agg(rk ORDER BY rn) FROM c2b));

-- 3. addon ordering
SET rum.ordered_candidate_pruning=off; SET rum.trgm_rank_from_match=off;
CREATE TEMP TABLE c3a AS SELECT row_number() OVER () rn, ctid tid,
       float4send(("time" <=| 500)::float4) rk
FROM (SELECT ctid, "time" FROM test_79 WHERE tsv @@ to_tsquery('wordA')
      ORDER BY "time" <=| 500 LIMIT 50) s;
SET rum.ordered_candidate_pruning=on; SET rum.trgm_rank_from_match=on;
CREATE TEMP TABLE c3b AS SELECT row_number() OVER () rn, ctid tid,
       float4send(("time" <=| 500)::float4) rk
FROM (SELECT ctid, "time" FROM test_79 WHERE tsv @@ to_tsquery('wordA')
      ORDER BY "time" <=| 500 LIMIT 50) s;
SELECT 'ctl addon identical='
    || ((SELECT array_agg(tid ORDER BY rn) FROM c3a) IS NOT DISTINCT FROM (SELECT array_agg(tid ORDER BY rn) FROM c3b))
    || ' rank='
    || ((SELECT array_agg(rk ORDER BY rn) FROM c3a) IS NOT DISTINCT FROM (SELECT array_agg(rk ORDER BY rn) FROM c3b));
EOF
}

writes() {
    # Control, not an optimization target: both patches touch only the scan
    # path, so every figure here should be flat between A and C.  A
    # difference would mean one of them reached the write side, which is a
    # defect rather than a result.
    printf "%-16s %-6s %12s %14s %8s\n" operation mode "median ms" "WAL bytes" runs
    for op in insert update delete_vacuum create_index; do
        case $op in
            insert)        stmt="INSERT INTO w_bench SELECT id + 1000000, body FROM msgs LIMIT 2000;" ;;
            update)        stmt="UPDATE w_bench SET body = body || ' zz' WHERE id % 5 = 0;" ;;
            delete_vacuum) stmt="DELETE FROM w_bench WHERE id % 5 = 0; VACUUM w_bench;" ;;
            create_index)  stmt="CREATE INDEX w_bench_rum ON w_bench USING rum (body rum_trgm_ops);" ;;
        esac
        if [ "$op" = create_index ]; then premake=""; else
            premake="CREATE INDEX w_bench_rum ON w_bench USING rum (body rum_trgm_ops);"; fi
        for mode in A C; do
            ms_list=""; wal_list=""
            for i in 1 2 3; do
                out=$(su postgres -c "$PSQL" <<EOF 2>&1
SET max_parallel_workers_per_gather=0;
$(guc_for $mode)
DROP TABLE IF EXISTS w_bench;
CREATE TABLE w_bench AS SELECT id, body FROM msgs;
$premake
CHECKPOINT;
CREATE TEMP TABLE mark AS SELECT pg_current_wal_lsn() l, clock_timestamp() t;
$stmt
SELECT round(extract(epoch from (clock_timestamp() - (SELECT t FROM mark))) * 1000)::text || ' ms_marker';
SELECT (pg_current_wal_lsn() - (SELECT l FROM mark))::text || ' wal_marker';
DROP TABLE mark;
EOF
)
                ms=$(echo "$out" | grep -oE "[0-9]+ ms_marker" | awk '{print $1}')
                wal=$(echo "$out" | grep -oE "[0-9]+ wal_marker" | awk '{print $1}')
                ms_list="$ms_list$ms\n"; wal_list="$wal_list$wal\n"
            done
            printf "%-16s %-6s %12s %14s %8s\n" "$op" "$mode" \
                   "$(echo -e "$ms_list" | grep -v '^$' | median)" \
                   "$(echo -e "$wal_list" | grep -v '^$' | median)" 3
        done
    done
    su postgres -c "$PSQL -c 'DROP TABLE IF EXISTS w_bench'" >/dev/null 2>&1
}

case "${1:-timings}" in
    timings)  timings ;;
    controls) controls ;;
    writes)   writes ;;
    *) echo "usage: $0 {timings|counters|controls}" >&2; exit 1 ;;
esac
