#!/bin/bash
# Benchmark for the ordered-trigram work.
#
# The branch has no run-time switch for these changes, so one run measures
# this branch only.  For a baseline, run the same script against an
# unpatched RUM on the same corpus and diff the tables.
#
# Warm median of N runs per point.
#
# Usage:
#   bench_ordered.sh timings
#   bench_ordered.sh controls
#   bench_ordered.sh writes     write-side control: expect no difference
set -u
PSQL="/home/claude/pg20/bin/psql -h /tmp/pgsock20 -p 5455 -X -qtA t20"
RUNS=5
Q="I am attaching the patch for the current master branch and the test results"

run_as() { su postgres -c "$PSQL $*"; }

median() { sort -n | awk '{a[NR]=$1} END {print (NR%2) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}'; }


# Expected RUM index per benchmark table.  The benchmark must measure the
# index it claims to measure: enable_seqscan=off is only a planner
# penalty, so a missing index produces a sequential scan, correct answers
# and a meaningless number.  One such run took 20.8 s instead of 214 ms
# and looked like a result.
idx_for() { case "$1" in msgs) echo msgs_rum ;; big_c) echo big_rum ;; esac; }

preflight() {
    local fail=0 tbl idx nidx nseq plan got

    for tbl in msgs big_c; do
        idx=$(idx_for "$tbl")

        # 1. the index exists
        if [ "$(su postgres -c "$PSQL" <<EOF
SELECT to_regclass('$idx') IS NOT NULL;
EOF
)" != "t" ]; then
            echo "ERROR: benchmark precondition failed:" >&2
            echo "  index $idx on $tbl does not exist" >&2
            echo "  create it with:" >&2
            echo "    CREATE INDEX $idx ON $tbl USING rum (body rum_trgm_ops);" >&2
            fail=1
            continue
        fi

        # 2. the plan really uses that index
        plan=$(su postgres -c "$PSQL" <<EOF
SET enable_seqscan=off;
SET pg_trgm.similarity_threshold=0.15;
EXPLAIN (FORMAT JSON) SELECT body FROM $tbl WHERE body % '$Q' ORDER BY body <-> '$Q' LIMIT 10;
EOF
)
        if ! printf '%s' "$plan" | python3 -c "
import sys, json
want = sys.argv[1]
plan = json.load(sys.stdin)[0]['Plan']
def walk(n):
    if n.get('Index Name') == want and 'Index Scan' in n['Node Type']:
        return True
    return any(walk(c) for c in n.get('Plans', []))
sys.exit(0 if walk(plan) else 1)
" "$idx" 2>/dev/null; then
            got=$(printf '%s' "$plan" | python3 -c "
import sys, json
plan = json.load(sys.stdin)[0]['Plan']
def first(n):
    if 'Scan' in n['Node Type']:
        return n['Node Type'] + (' using ' + n['Index Name'] if 'Index Name' in n else '')
    for c in n.get('Plans', []):
        r = first(c)
        if r:
            return r
    return None
print(first(plan) or plan['Node Type'])" 2>/dev/null)
            echo "ERROR: benchmark precondition failed:" >&2
            echo "  expected Index Scan using $idx" >&2
            echo "  got ${got:-unparseable plan}" >&2
            fail=1
            continue
        fi

        # 3. the index answers the same as a sequential scan
        nidx=$(su postgres -c "$PSQL" <<EOF
SET enable_seqscan=off;
SET pg_trgm.similarity_threshold=0.15;
SELECT count(*) FROM $tbl WHERE body % '$Q';
EOF
)
        nseq=$(su postgres -c "$PSQL" <<EOF
SET enable_indexscan=off;
SET enable_bitmapscan=off;
SET pg_trgm.similarity_threshold=0.15;
SELECT count(*) FROM $tbl WHERE body % '$Q';
EOF
)
        if [ "$nidx" != "$nseq" ]; then
            echo "ERROR: benchmark precondition failed:" >&2
            echo "  $tbl: index returned $nidx rows, sequential scan returned $nseq" >&2
            fail=1
            continue
        fi

        printf "preflight %-6s ok: Index Scan using %-8s rows=%s\n" "$tbl" "$idx" "$nidx"
    done

    [ "$fail" = 0 ] || exit 1
}

timings() {
    preflight
    printf "%-8s %-6s %-6s %10s %10s\n" corpus t limit "median ms" "runs"
    for tbl in msgs big_c; do
        for t in 0.05 0.10 0.15; do
            for lim in 10 100; do
                    # two warm-ups, then RUNS measured executions
                    out=$(su postgres -c "$PSQL" <<EOF 2>&1
SET max_parallel_workers_per_gather=0; SET enable_seqscan=off;
SET pg_trgm.similarity_threshold=$t;
SELECT count(*) FROM (SELECT body FROM $tbl WHERE body % '$Q' ORDER BY body <-> '$Q' LIMIT $lim) x;
SELECT count(*) FROM (SELECT body FROM $tbl WHERE body % '$Q' ORDER BY body <-> '$Q' LIMIT $lim) x;
$(for i in $(seq 1 $RUNS); do
    echo "EXPLAIN (ANALYZE, COSTS OFF) SELECT body FROM $tbl WHERE body % '$Q' ORDER BY body <-> '$Q' LIMIT $lim;"
  done)
EOF
)
                    med=$(echo "$out" | grep -oE "Execution Time: [0-9.]+" | awk '{print $3}' | median)
                printf "%-8s %-6s %-6s %10s %10s\n" "$tbl" "$t" "$lim" "$med" "$RUNS"
            done
        done
    done
}

controls() {
    # These shapes must not take the reuse path: the ordering asks a
    # different question, or the opclass is not trigram.  Without a
    # run-time switch the meaningful check is the index against a
    # sequential scan.
    #
    # No LIMIT: with one, ties at the limit boundary are broken
    # arbitrarily and the two plans break them differently.  The addon
    # |=> case puts many rows at Infinity and then differs in rank bytes,
    # which looks like a failure and is not one.
    echo "-- controls: index results must equal a sequential scan"
    su postgres -c "$PSQL" <<'EOF' 2>&1 | grep -E "ctl "
SET max_parallel_workers_per_gather=0;
SET pg_trgm.similarity_threshold=0.15;

-- 1. different query in WHERE and ORDER BY: not a duplicate key, so the
--    match evidence cannot be reused for ranking.
SET enable_indexscan=off; SET enable_bitmapscan=off; SET enable_seqscan=on;
CREATE TEMP TABLE c1a AS SELECT ctid tid,
       float4send((body <-> 'logical replication slot conflict')::float4) rk
FROM big_c
 WHERE body % 'I am attaching the patch for the current master branch and the test results';
SET enable_seqscan=off; SET enable_indexscan=on; SET enable_bitmapscan=on;
CREATE TEMP TABLE c1b AS SELECT ctid tid,
       float4send((body <-> 'logical replication slot conflict')::float4) rk
FROM big_c
 WHERE body % 'I am attaching the patch for the current master branch and the test results';
SELECT 'ctl different-order-by-query tids='
    || ((SELECT array_agg(tid ORDER BY tid) FROM c1a) IS NOT DISTINCT FROM (SELECT array_agg(tid ORDER BY tid) FROM c1b))
    || ' rank='
    || ((SELECT array_agg(rk ORDER BY tid) FROM c1a) IS NOT DISTINCT FROM (SELECT array_agg(rk ORDER BY tid) FROM c1b));

-- 2. tsvector ordering
SET enable_indexscan=off; SET enable_bitmapscan=off; SET enable_seqscan=on;
CREATE TEMP TABLE c2a AS SELECT ctid tid,
       float4send(tsv <=> to_tsquery('english','foo & bar')) rk
FROM fts WHERE tsv @@ to_tsquery('english','foo & bar');
SET enable_seqscan=off; SET enable_indexscan=on; SET enable_bitmapscan=on;
CREATE TEMP TABLE c2b AS SELECT ctid tid,
       float4send(tsv <=> to_tsquery('english','foo & bar')) rk
FROM fts WHERE tsv @@ to_tsquery('english','foo & bar');
SELECT 'ctl tsvector tids='
    || ((SELECT array_agg(tid ORDER BY tid) FROM c2a) IS NOT DISTINCT FROM (SELECT array_agg(tid ORDER BY tid) FROM c2b))
    || ' rank='
    || ((SELECT array_agg(rk ORDER BY tid) FROM c2a) IS NOT DISTINCT FROM (SELECT array_agg(rk ORDER BY tid) FROM c2b));

-- 3. addon ordering, which this branch excludes from the candidate-aware path
SET enable_indexscan=off; SET enable_bitmapscan=off; SET enable_seqscan=on;
CREATE TEMP TABLE c3a AS SELECT ctid tid, float4send(("time" <=| 500)::float4) rk
FROM test_79 WHERE tsv @@ to_tsquery('wordA');
SET enable_seqscan=off; SET enable_indexscan=on; SET enable_bitmapscan=on;
CREATE TEMP TABLE c3b AS SELECT ctid tid, float4send(("time" <=| 500)::float4) rk
FROM test_79 WHERE tsv @@ to_tsquery('wordA');
SELECT 'ctl addon tids='
    || ((SELECT array_agg(tid ORDER BY tid) FROM c3a) IS NOT DISTINCT FROM (SELECT array_agg(tid ORDER BY tid) FROM c3b))
    || ' rank='
    || ((SELECT array_agg(rk ORDER BY tid) FROM c3a) IS NOT DISTINCT FROM (SELECT array_agg(rk ORDER BY tid) FROM c3b));
EOF
}

writes() {
    # Control, not an optimization target: the branch touches only the scan
    # path, so these figures should match an unpatched RUM on the same
    # corpus.  A difference would mean the change reached the write side.
    printf "%-16s %12s %14s %8s\n" operation "median ms" "WAL bytes" runs
    for op in insert update delete_vacuum create_index; do
        case $op in
            insert)        stmt="INSERT INTO w_bench SELECT id + 1000000, body FROM msgs LIMIT 2000;" ;;
            update)        stmt="UPDATE w_bench SET body = body || ' zz' WHERE id % 5 = 0;" ;;
            delete_vacuum) stmt="DELETE FROM w_bench WHERE id % 5 = 0; VACUUM w_bench;" ;;
            create_index)  stmt="CREATE INDEX w_bench_rum ON w_bench USING rum (body rum_trgm_ops);" ;;
        esac
        if [ "$op" = create_index ]; then premake=""; else
            premake="CREATE INDEX w_bench_rum ON w_bench USING rum (body rum_trgm_ops);"; fi
        ms_list=""; wal_list=""
        for i in 1 2 3; do
                out=$(su postgres -c "$PSQL" <<EOF 2>&1
SET max_parallel_workers_per_gather=0;
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
        printf "%-16s %12s %14s %8s\n" "$op" \
               "$(echo -e "$ms_list" | grep -v '^$' | median)" \
               "$(echo -e "$wal_list" | grep -v '^$' | median)" 3
    done
    su postgres -c "$PSQL -c 'DROP TABLE IF EXISTS w_bench'" >/dev/null 2>&1
}

case "${1:-timings}" in
    timings)  timings ;;
    controls) controls ;;
    writes)   writes ;;
    *) echo "usage: $0 {timings|counters|controls}" >&2; exit 1 ;;
esac
