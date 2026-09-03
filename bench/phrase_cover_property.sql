-- Property test for the derived cover on positional queries.
--
-- The safety property is set inclusion: every document a sequential scan
-- accepts must also be produced by the index scan whose candidates come
-- from the derived cover.  A cover that is too small drops true matches.
--
-- Random vocabulary pairs are rarely adjacent, so this corpus plants
-- adjacency deliberately.
\set ON_ERROR_STOP on
SET max_parallel_workers_per_gather = 0;

DROP TABLE IF EXISTS phrase_cover;
CREATE TABLE phrase_cover (id serial primary key, body text, tsv tsvector);
INSERT INTO phrase_cover (body)
SELECT (ARRAY['a b','a x b','a b c','b a','a a b','x a b y','a x x b','b c a',
              'a b a b','c a b','a','b','a b b','q a b','a b q'])[1 + (i % 15)]
       || ' ' || (ARRAY['','pad1','pad2 pad3',''])[1 + (i % 4)]
FROM generate_series(1, 3000) i;
UPDATE phrase_cover SET tsv = to_tsvector('simple', body);
CREATE INDEX phrase_cover_idx ON phrase_cover USING rum (tsv rum_tsvector_ops);

DROP TABLE IF EXISTS phrase_cover_result;
CREATE TABLE phrase_cover_result(q text, seq int, idx int, missing int, extra int);

DO $$
DECLARE qs text[] := ARRAY[
  'a <-> b', 'b <-> a', 'a <2> b', 'a <3> b', 'a <-> b <-> c', 'a <-> a <-> b',
  'a <-> x <-> b', '(a <-> b) & c', '(a <-> b) | c', '(a <-> b) & !c',
  'a & (b <-> c)', '!(a <-> b) & q', '(a <-> b) & (b <-> c)', 'a <-> b & q',
  '(a <2> b) | (b <-> a)', 'pad1 & (a <-> b)', 'a <-> b <-> a', 'q <-> a <-> b'];
  qt text; q tsquery; s int[]; x int[];
BEGIN
  FOREACH qt IN ARRAY qs LOOP
    BEGIN q := to_tsquery('simple', qt); EXCEPTION WHEN others THEN CONTINUE; END;
    SET LOCAL enable_indexscan=off; SET LOCAL enable_bitmapscan=off; SET LOCAL enable_seqscan=on;
    SELECT array_agg(id ORDER BY id) INTO s FROM phrase_cover WHERE tsv @@ q;
    SET LOCAL enable_seqscan=off; SET LOCAL enable_indexscan=on; SET LOCAL enable_bitmapscan=on;
    SELECT array_agg(id ORDER BY id) INTO x FROM phrase_cover WHERE tsv @@ q;
    INSERT INTO phrase_cover_result
      SELECT qt, coalesce(array_length(s,1),0), coalesce(array_length(x,1),0),
        (SELECT count(*) FROM unnest(coalesce(s,'{}')) v WHERE v <> ALL (coalesce(x,'{}'))),
        (SELECT count(*) FROM unnest(coalesce(x,'{}')) v WHERE v <> ALL (coalesce(s,'{}')));
  END LOOP;
END $$;

SELECT rpad(q,24) || ' seq=' || lpad(seq::text,4) || ' idx=' || lpad(idx::text,4)
    || ' missing=' || missing || ' extra=' || extra
FROM phrase_cover_result ORDER BY q;

SELECT 'PHRASE TOTAL missing=' || sum(missing) || ' extra=' || sum(extra)
    || ' nonempty=' || count(*) FILTER (WHERE seq > 0) || '/' || count(*)
FROM phrase_cover_result;
