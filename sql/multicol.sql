/*
 * Multicolumn scans: a conjunction over two attributes of one RUM index
 * must return the same rows as a sequential scan.  Before the fix the
 * fast scan mistook the attribute boundary in its entry array for a
 * position boundary, and this query returned no rows.
 */
CREATE TABLE multicol_test (
	id  int,
	t1  tsvector,
	t2  tsvector
);

/*
 * The table has to be large enough for the entries to reach a posting
 * tree; at twenty rows the broken scan happens to terminate and the test
 * would pass either way.
 */
INSERT INTO multicol_test
SELECT i,
       to_tsvector('simple', (ARRAY['alpha beta','alpha gamma','beta gamma',
                                    'alpha beta gamma','delta'])[1 + i % 5]),
       to_tsvector('simple', (ARRAY['red green','red blue','green blue',
                                    'red green blue','white'])[1 + (i*3) % 5])
FROM generate_series(1, 4000) i;

CREATE INDEX multicol_idx ON multicol_test
	USING rum (t1 rum_tsvector_ops, t2 rum_tsvector_ops);

SET enable_seqscan = off;

/*
 * Without the fix the cross-attribute cases below do not return at all,
 * so bound them: a timeout is a failure, not a hung buildfarm animal.
 */
SET statement_timeout = '60s';

-- each attribute alone
SELECT count(*) FROM multicol_test WHERE t1 @@ to_tsquery('simple', 'alpha');
SELECT count(*) FROM multicol_test WHERE t2 @@ to_tsquery('simple', 'red');

-- the conjunction: every row matches both
SELECT count(*) FROM multicol_test
 WHERE t1 @@ to_tsquery('simple', 'alpha')
   AND t2 @@ to_tsquery('simple', 'red');

-- and one that matches nothing on the second attribute
SELECT count(*) FROM multicol_test
 WHERE t1 @@ to_tsquery('simple', 'alpha')
   AND t2 @@ to_tsquery('simple', 'blue');

-- ordering by the other attribute: the order-by key contributes entries
-- of its own, so this reaches the same array through a different route
SELECT count(*) FROM (
	SELECT id FROM multicol_test
	 WHERE t1 @@ to_tsquery('simple', 'alpha')
	 ORDER BY t2 <=> to_tsquery('simple', 'red')
	 LIMIT 5) x;

-- two keys on the same attribute keep working
SELECT count(*) FROM multicol_test
 WHERE t1 @@ to_tsquery('simple', 'alpha')
   AND t1 @@ to_tsquery('simple', 'beta');

RESET enable_seqscan;
DROP TABLE multicol_test;
