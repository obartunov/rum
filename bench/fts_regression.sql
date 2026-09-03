-- Compare three modes on one binary for existing FTS ranking semantics.
--   A: both research GUCs off        (baseline)
--   B: ordered_candidate_pruning on
--   C: B + trgm_rank_from_match on
-- For every case: TID sequence, rank bytes (float4send), row count.
\set ON_ERROR_STOP on
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;

DROP TABLE IF EXISTS res;
CREATE TEMP TABLE res(mode text, caseid text, rn int, tid tid, rank bytea);

CREATE OR REPLACE FUNCTION run_cases(mode text) RETURNS void AS $$
BEGIN
  -- 1. plain tsquery + ORDER BY <=>
  INSERT INTO res SELECT mode, '1-plain', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> to_tsquery('english','foo & bar')) rk
    FROM fts WHERE tsv @@ to_tsquery('english','foo & bar')
    ORDER BY tsv <=> to_tsquery('english','foo & bar') LIMIT 100) s;

  -- 2. phrase tsquery: positions are part of the meaning
  INSERT INTO res SELECT mode, '2-phrase', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> phraseto_tsquery('english','foo qux bar')) rk
    FROM fts WHERE tsv @@ phraseto_tsquery('english','foo qux bar')
    ORDER BY tsv <=> phraseto_tsquery('english','foo qux bar') LIMIT 100) s;

  -- 3. AND / OR / NOT
  INSERT INTO res SELECT mode, '3-and', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> to_tsquery('english','alpha & epsilon')) rk
    FROM fts WHERE tsv @@ to_tsquery('english','alpha & epsilon')
    ORDER BY tsv <=> to_tsquery('english','alpha & epsilon') LIMIT 100) s;
  INSERT INTO res SELECT mode, '3-or', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> to_tsquery('english','epsilon | tail3')) rk
    FROM fts WHERE tsv @@ to_tsquery('english','epsilon | tail3')
    ORDER BY tsv <=> to_tsquery('english','epsilon | tail3') LIMIT 100) s;
  INSERT INTO res SELECT mode, '3-not', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> to_tsquery('english','foo & !qux')) rk
    FROM fts WHERE tsv @@ to_tsquery('english','foo & !qux')
    ORDER BY tsv <=> to_tsquery('english','foo & !qux') LIMIT 100) s;

  -- 4. weights
  INSERT INTO res SELECT mode, '4-weight', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> to_tsquery('english','foo:A | bar:*')) rk
    FROM fts WHERE tsv @@ to_tsquery('english','foo:A | bar:*')
    ORDER BY tsv <=> to_tsquery('english','foo:A | bar:*') LIMIT 100) s;

  -- 5/6. ties, and the full ordered output with no LIMIT
  INSERT INTO res SELECT mode, '6-full', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> to_tsquery('english','epsilon')) rk
    FROM fts WHERE tsv @@ to_tsquery('english','epsilon')
    ORDER BY tsv <=> to_tsquery('english','epsilon')) s;

  -- 7. LIMIT 1 / 10
  INSERT INTO res SELECT mode, '7-lim1', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> to_tsquery('english','foo & bar')) rk
    FROM fts WHERE tsv @@ to_tsquery('english','foo & bar')
    ORDER BY tsv <=> to_tsquery('english','foo & bar') LIMIT 1) s;
  INSERT INTO res SELECT mode, '7-lim10', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> to_tsquery('english','foo & bar')) rk
    FROM fts WHERE tsv @@ to_tsquery('english','foo & bar')
    ORDER BY tsv <=> to_tsquery('english','foo & bar') LIMIT 10) s;

  -- 8. predicate simpler than the ordering: q1 <> q2
  INSERT INTO res SELECT mode, '8-q1nq2', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(tsv <=> to_tsquery('english','epsilon')) rk
    FROM fts WHERE tsv @@ to_tsquery('english','foo & bar')
    ORDER BY tsv <=> to_tsquery('english','epsilon') LIMIT 100) s;

  -- 9. addon ordering: symmetric and both asymmetric forms (issue 79 shape)
  INSERT INTO res SELECT mode, '9-addon-sym', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(("time" <=> 500)::float4) rk
    FROM test_79 WHERE tsv @@ to_tsquery('wordA')
    ORDER BY "time" <=> 500 LIMIT 50) s;
  INSERT INTO res SELECT mode, '9-addon-left', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(("time" <=| 500)::float4) rk
    FROM test_79 WHERE tsv @@ to_tsquery('wordA')
    ORDER BY "time" <=| 500 LIMIT 50) s;
  INSERT INTO res SELECT mode, '9-addon-right', row_number() OVER (), tid, rk FROM (
    SELECT ctid tid, float4send(("time" |=> 500)::float4) rk
    FROM test_79 WHERE tsv @@ to_tsquery('wordA')
    ORDER BY "time" |=> 500 LIMIT 50) s;
END $$ LANGUAGE plpgsql;

SELECT run_cases('A');

SELECT run_cases('B');

SELECT run_cases('C');

SELECT caseid
    || ' rows=' || (SELECT count(*) FROM res r WHERE r.mode='A' AND r.caseid=x.caseid)
    || ' B_tid=' || ((SELECT array_agg(tid ORDER BY rn) FROM res r WHERE r.mode='A' AND r.caseid=x.caseid)
                 IS NOT DISTINCT FROM
                     (SELECT array_agg(tid ORDER BY rn) FROM res r WHERE r.mode='B' AND r.caseid=x.caseid))
    || ' B_rank=' || ((SELECT array_agg(rank ORDER BY rn) FROM res r WHERE r.mode='A' AND r.caseid=x.caseid)
                  IS NOT DISTINCT FROM
                      (SELECT array_agg(rank ORDER BY rn) FROM res r WHERE r.mode='B' AND r.caseid=x.caseid))
    || ' C_tid=' || ((SELECT array_agg(tid ORDER BY rn) FROM res r WHERE r.mode='A' AND r.caseid=x.caseid)
                 IS NOT DISTINCT FROM
                     (SELECT array_agg(tid ORDER BY rn) FROM res r WHERE r.mode='C' AND r.caseid=x.caseid))
    || ' C_rank=' || ((SELECT array_agg(rank ORDER BY rn) FROM res r WHERE r.mode='A' AND r.caseid=x.caseid)
                  IS NOT DISTINCT FROM
                      (SELECT array_agg(rank ORDER BY rn) FROM res r WHERE r.mode='C' AND r.caseid=x.caseid))
   AS result
FROM (SELECT DISTINCT caseid FROM res) x ORDER BY 1;
