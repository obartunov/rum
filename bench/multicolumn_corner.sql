-- Single-key predicates on a multicolumn index: the cover must be derived
-- inside one scan key and one attribute, never spanning columns.  A word
-- that exists only in the other column must return nothing.
\set ON_ERROR_STOP on
SET max_parallel_workers_per_gather = 0;

DROP TABLE IF EXISTS mc_corner;
CREATE TABLE mc_corner AS
SELECT i AS id,
  to_tsvector('simple', (ARRAY['alpha beta','alpha gamma','beta gamma',
                               'alpha beta gamma','delta'])[1 + i % 5]) AS t1,
  to_tsvector('simple', (ARRAY['red green','red blue','green blue',
                               'red green blue','white'])[1 + (i*3) % 5]) AS t2
FROM generate_series(1, 4000) i;
CREATE INDEX mc_corner_idx ON mc_corner USING rum (t1 rum_tsvector_ops, t2 rum_tsvector_ops);

DO $$
DECLARE preds text[] := ARRAY[
   't1 @@ to_tsquery(''simple'',''alpha & beta'')',
   't1 @@ to_tsquery(''simple'',''alpha | delta'')',
   't2 @@ to_tsquery(''simple'',''red & green'')',
   't2 @@ to_tsquery(''simple'',''blue | white'')',
   't1 @@ to_tsquery(''simple'',''alpha & red'')',
   't2 @@ to_tsquery(''simple'',''red & alpha'')'];
  k int; s int; x int; bad int := 0;
BEGIN
  FOR k IN 1..array_length(preds,1) LOOP
    SET LOCAL enable_indexscan=off; SET LOCAL enable_bitmapscan=off; SET LOCAL enable_seqscan=on;
    EXECUTE 'SELECT count(*) FROM mc_corner WHERE ' || preds[k] INTO s;
    SET LOCAL enable_seqscan=off; SET LOCAL enable_indexscan=on; SET LOCAL enable_bitmapscan=on;
    EXECUTE 'SELECT count(*) FROM mc_corner WHERE ' || preds[k] INTO x;
    RAISE NOTICE '% : seq=% idx=% %', preds[k], s, x,
                 CASE WHEN s = x THEN 'OK' ELSE 'MISMATCH' END;
    IF s <> x THEN bad := bad + 1; END IF;
  END LOOP;
  RAISE NOTICE 'multicolumn single-key corner: mismatches=%', bad;
END $$;
