-- Property test for the preConsistent-derived candidate cover.
--
-- The safety property is set inclusion, not speed: every document that a
-- sequential scan accepts must also be produced by the index scan whose
-- candidates come from the derived cover.  A cover that is too small
-- would drop true matches; that is the failure this looks for.
--
-- Shapes covered: single term, AND, OR, NOT, mixed AND/NOT, nested
-- parenthesised expressions, duplicate terms, weighted terms, phrase,
-- and phrase inside a boolean.  Queries are generated from the corpus
-- vocabulary so that they actually match something.
\set ON_ERROR_STOP on
SET max_parallel_workers_per_gather = 0;

-- Corpus: a small vocabulary so that generated queries actually match,
-- with weights and repeated terms.
DROP TABLE IF EXISTS prop;
CREATE TABLE prop AS
SELECT i AS id,
       (SELECT string_agg(w, ' ') FROM (
          SELECT (ARRAY['alpha','beta','gamma','delta','eps','zeta','eta',
                        'theta','iota','kappa','lam','mu'])[1 + ((i*7 + g*13) % 12)] AS w
          FROM generate_series(1, 3 + (i % 9)) g) s) AS body
FROM generate_series(1, 4000) i;
ALTER TABLE prop ADD COLUMN tsv tsvector;
UPDATE prop SET tsv = setweight(to_tsvector('simple', body),
                                (ARRAY['A','B','C','D'])[1 + id % 4]::"char");
CREATE INDEX prop_rum ON prop USING rum (tsv rum_tsvector_ops);

DROP TABLE IF EXISTS prop_result;
CREATE TABLE prop_result(shape text, q text, seq_rows int, idx_rows int,
                         missing int, extra int);

DO $$
DECLARE
    vocab text[] := ARRAY['alpha','beta','gamma','delta','eps','zeta',
                          'eta','theta','iota','kappa','lam','mu'];
    w1 text; w2 text; w3 text;
    shapes text[] := ARRAY['single','and','or','not','and_not','nested',
                           'dup','weight','phrase','phrase_bool'];
    shape text;
    qtext text;
    q tsquery;
    seq_ids int[];
    idx_ids int[];
    i int;
BEGIN
    FOR i IN 1..300 LOOP
        w1 := vocab[1 + (random() * 11)::int];
        w2 := vocab[1 + (random() * 11)::int];
        w3 := vocab[1 + (random() * 11)::int];
        shape := shapes[1 + (random() * (array_length(shapes,1) - 1))::int];

        qtext := CASE shape
            WHEN 'single'      THEN w1
            WHEN 'and'         THEN w1 || ' & ' || w2
            WHEN 'or'          THEN w1 || ' | ' || w2
            WHEN 'not'         THEN w1 || ' & !' || w2
            WHEN 'and_not'     THEN w1 || ' & ' || w2 || ' & !' || w3
            WHEN 'nested'      THEN '(' || w1 || ' | ' || w2 || ') & ' || w3
            WHEN 'dup'         THEN w1 || ' & ' || w1 || ' & ' || w2
            WHEN 'weight'      THEN w1 || ':A | ' || w2 || ':B'
            WHEN 'phrase'      THEN w1 || ' <-> ' || w2
            WHEN 'phrase_bool' THEN '(' || w1 || ' <-> ' || w2 || ') | ' || w3
        END;

        BEGIN
            q := to_tsquery('simple', qtext);
        EXCEPTION WHEN others THEN
            CONTINUE;   -- unparseable combination, skip
        END;

        SET LOCAL enable_indexscan = off;
        SET LOCAL enable_bitmapscan = off;
        SET LOCAL enable_seqscan = on;
        SELECT array_agg(id ORDER BY id) INTO seq_ids FROM prop WHERE tsv @@ q;

        SET LOCAL enable_seqscan = off;
        SET LOCAL enable_indexscan = on;
        SET LOCAL enable_bitmapscan = on;
        SELECT array_agg(id ORDER BY id) INTO idx_ids FROM prop WHERE tsv @@ q;

        INSERT INTO prop_result
        SELECT shape, qtext,
               coalesce(array_length(seq_ids,1),0),
               coalesce(array_length(idx_ids,1),0),
               (SELECT count(*) FROM unnest(coalesce(seq_ids,'{}')) s
                 WHERE s <> ALL (coalesce(idx_ids,'{}'))),
               (SELECT count(*) FROM unnest(coalesce(idx_ids,'{}')) x
                 WHERE x <> ALL (coalesce(seq_ids,'{}')));
    END LOOP;
END $$;

SELECT shape
    || ' queries=' || count(*)
    || ' nonempty=' || count(*) FILTER (WHERE seq_rows > 0)
    || ' rows=' || coalesce(sum(seq_rows),0)
    || ' missing=' || coalesce(sum(missing),0)
    || ' extra=' || coalesce(sum(extra),0)
FROM prop_result GROUP BY shape ORDER BY shape;

SELECT 'TOTAL missing=' || coalesce(sum(missing),0)
    || ' extra=' || coalesce(sum(extra),0)
    || ' over ' || count(*) || ' queries, ' || coalesce(sum(seq_rows),0) || ' matched rows'
FROM prop_result;
