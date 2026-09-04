# Experimental RUM ranked-search branch

This branch explores improvements to ranked search in RUM while
preserving the existing index format and write path. It lets compatible
ordered scans derive a safe candidate-generation cover from opclass
semantics, retain candidate-specific pruning where available, and reuse
index evidence for ranking when the search and ordering expressions are
proven equivalent.

It also fixes a correctness bug in multicolumn scans that is independent
of the rest of the branch.

Base: `postgrespro/rum` at `d81c73f`. Developed and tested against
PostgreSQL 20devel built with `--enable-cassert`. The upstream README is
kept as `README.rum.md`.

## What this branch changes

**A multicolumn correctness fix.** A query whose scan touches two
attributes of one RUM index could spin in `scanGetItemFast` until the OOM
killer stopped the backend, or, depending on the data, return no rows.
The fast scan keeps every entry in one array ordered by `cmpEntries()`
and looks for the border at which `preConsistent()` turns false, treating
the array as a single stream of positions. That ordering is positional
only within one attribute: `cmpEntries()` compares `attnumOrig` first and
never reaches the item pointers when the attributes differ. The branch
uses the regular scan when the entries span several attributes.

**Three separate mechanisms for ranked search**, worth naming apart
because they pay in different situations:

- *candidate-generation cover* — the set of entries that every matching
  row must intersect, so that merging only those still produces every
  candidate. Previously computed arithmetically from an opclass query
  minimum; now also derived from `preConsistent` for opclasses that
  cannot state such a minimum, which is how `rum_tsvector_ops` reaches
  this path at all.
- *candidate-specific pruning* — rejecting a candidate from the
  document's own payload before probing the remaining entries. Available
  where the opclass provides a per-candidate bound, as `rum_trgm` does.
- *evidence reuse* — when the order-by key asks the same question of the
  same attribute as the search key, ranking takes the evidence the
  matching side already gathered instead of reading the same postings
  again.

## Why

An ordered query lost the candidate-aware machinery entirely: one
order-by key dropped the whole scan onto a different path. Matching
evidence and ordering evidence were treated as belonging to separate
scans even when they were the same evidence. And the arithmetic form of
the cover excluded full-text search by construction.

## Results

Ranked trigram similarity, `WHERE body % q ORDER BY body <-> q LIMIT n`,
200 000 documents, warm median of five runs, one binary:

| threshold | baseline | + candidate-aware ordered | + evidence reuse |
|---|---|---|---|
| 0.05, LIMIT 10 | 867 ms | 667 ms | 433 ms |
| 0.10, LIMIT 10 | 722 ms | 367 ms | 279 ms |
| 0.15, LIMIT 10 | 715 ms | 221 ms | 218 ms |

**1.6x–3.5x on the tested ranked trigram similarity workload.** The same
shape appears on a 10 000-document corpus, so the effect is not an
artifact of the duplication used to build the larger one.

The two mechanisms pay in opposite regimes, which the counters show:

- **strong rejection favours the cover and pruning.** At threshold 0.15,
  99% of candidates are rejected before any probe, and that is where the
  ordered scan gets its 3.2x.
- **many ranking survivors favour evidence reuse.** At threshold 0.05,
  111 040 candidates reach ranking and 3.66M redundant seeks disappear;
  at 0.15 only 900 do, and reuse is within noise.

Ranked full-text search, `WHERE tsv @@ q ORDER BY tsv <=> q`, 20 000
documents:

| query | change |
|---|---|
| `foo & bar & alpha` | −22% |
| `phraseto_tsquery('foo qux bar')` | −15% |
| `(foo & bar) \| (epsilon & alpha)` | −25% |

These milliseconds are not comparable with the trigram table above:
different corpus, different opclass.

## Correctness checks

- `make installcheck` — 38 regression tests, including a `multicol` test
  that does not terminate without the fix, and a `rum_trgm` test checking
  trigram extraction against `pg_trgm` and index results against
  sequential scans at four thresholds.
- Cover safety, `bench/cover_property_test.sql`: 300 generated boolean
  queries over ten shapes, 435 331 matched rows, nothing lost or
  invented; the candidate-aware path engages for every eligible
  multi-entry query.
- Positional safety, `bench/phrase_cover_property.sql`: eighteen phrase
  queries on a corpus built for adjacency, seventeen non-empty, nothing
  lost.
- Multicolumn corner, `bench/multicolumn_corner.sql`: single-key
  predicates on a two-column index agree with sequential scans, and a
  word present only in the other column returns nothing.
- Evidence-reuse controls, `bench/fts_regression.sql`: `q1 <> q2`,
  ordering on a different column, `rum_tsvector_ops` and
  `rum_tsvector_addon_ops` ordering all keep the previous path and
  byte-identical results. Reuse activates only when the access method has
  proven the two keys equivalent, entry by entry.

## Write-path impact

**The patches do not change the index format, insertion, vacuum or WAL
paths.** Measured control, baseline against this branch:

- `INSERT`, `UPDATE` and `DELETE` produce **byte-identical WAL volume**.
- `CREATE INDEX`, `CREATE INDEX CONCURRENTLY` and `VACUUM` leave a
  **byte-identical index size**.
- No repeatable write-side latency difference. The small differences seen
  are in the direction and magnitude that cache warming explains, and a
  scan-only change cannot speed up an insert.

Unrelated to this branch but worth knowing before benchmarking: baseline
RUM's insert path is expensive without a pending list — inserting 10 000
rows into a `rum_trgm_ops` index took about 95 seconds and wrote about
5.98 GB of WAL on the test machine. Existing behaviour, and a subject for
future architectural work.

## Reproduce

    git clone https://github.com/postgrespro/rum.git
    cd rum
    git checkout d81c73f
    git fetch /path/to/rum-ranked-search.bundle 'refs/heads/*:refs/remotes/bundle/*'
    git checkout -b ranked bundle/oleg/rum-ranked-search

    make USE_PGXS=1
    pg_ctl -D $PGDATA stop            # install with the server stopped
    make USE_PGXS=1 install
    pg_ctl -D $PGDATA start
    make USE_PGXS=1 installcheck

### Benchmarks

The benchmark input is fixed and shipped with the branch, so reproducing
the numbers does not involve reproducing the corpus:

    bench/data/corpus_c10k.csv.gz        10 000 documents, 3.7 MB packed
    bench/data/corpus_c10k.sha256        checksums for packed and unpacked
    bench/data/corpus_c10k.manifest.json how it was derived

Two people running this benchmark are then comparing milliseconds on the
same bytes, which is the point.

    cd bench/data
    shasum -a 256 -c corpus_c10k.sha256   # checks the .gz
    gunzip -k corpus_c10k.csv.gz
    shasum -a 256 -c corpus_c10k.sha256   # now checks both
    cd ../..

    createdb bench
    psql -d bench -c "CREATE EXTENSION rum; CREATE EXTENSION pg_trgm; CREATE EXTENSION rum_trgm;"
    psql -d bench -c "CREATE TABLE msgs (msg_no int, chunk_no int, subject text, body text, id int)"
    psql -d bench -c "\copy msgs FROM 'bench/data/corpus_c10k.csv' CSV"
    psql -d bench -c "CREATE TABLE big_c AS SELECT (m.id + 10000*k) id, m.body FROM msgs m, generate_series(0,19) k"
    psql -d bench -c "CREATE INDEX big_rum ON big_c USING rum (body rum_trgm_ops)"

    bash bench/bench_ordered.sh timings      # the table above
    bash bench/bench_ordered.sh controls     # negative controls
    bash bench/bench_writes.sh               # write-path control

### Correctness tests need no corpus at all

They build their own tables and run against an empty database:

    createdb fresh
    psql -d fresh -c "CREATE EXTENSION rum"
    psql -d fresh -f bench/cover_property_test.sql
    psql -d fresh -f bench/phrase_cover_property.sql
    psql -d fresh -f bench/multicolumn_corner.sql

`make installcheck` likewise needs nothing beyond a running server.

### Where the corpus came from

`tools/generate_natural_corpus.py` is kept as provenance, not as a step
in reproducing anything.  It turned one month of the pgsql-hackers
archive — `pgsql-hackers.202203.mbox`, 80 639 431 bytes, sha256
`1a25dd24...80ccf2` — into the shipped CSV, deterministically: a pure
function of the input bytes, no sampling and no seed, with chunks taken
round-robin across messages so that 10 000 documents still span 3 236 of
the 3 594 messages.  Run it only if you want a different corpus; then the
absolute milliseconds are yours, not comparable with the table above.


## Scope / known limitations

- Partial-match entries are outside this work. One query entry expanding
  into many index keys is a different model and the cover argument does
  not carry over; such scans keep their existing path.
- A query with search keys on more than one attribute does not use the
  candidate-aware path.
- Evidence reuse requires the order-by key to be an ordinary entry-based
  key on the same attribute with the same entries. Alternative-order
  addon scans are excluded explicitly: routing them elsewhere returns no
  rows, which is how that exclusion was found.
- The trigram results come from one corpus family and one machine. The
  ratios are the claim; the absolute milliseconds are not portable.
- The multicolumn fix is a restriction rather than a repair: it makes the
  entry condition match the fast scan's actual precondition. Making the
  border search attribute-aware would be a redesign, needing a positional
  comparator across attributes that `cmpEntries()` does not provide.

## Commit structure

     1  Do not use the fast scan when its entries span several attributes
     2  Defer first-page decode of posting-tree scan entries
     3  Add opclass query-minimum-match support
     4  Generate scan candidates from a sufficient subset of entries
     5  Refine the match bound per candidate from document-level addInfo
     6  Add rum_trgm: trigram similarity opclass for RUM
     7  Cache candidate bounds in a direct-mapped table
     8  Run the rum_trgm exactness test as part of installcheck
     9  Derive the candidate-generation cover from preConsistent
    10  Let compatible ordered scans use the candidate-aware path
    11  Reuse matching evidence for equivalent ordering keys
    12  Add reproducible benchmarks, property tests and this README
    13  Ship the benchmark corpus instead of a recipe for building it

Commits 2–8 are the prerequisite machinery — what makes a
candidate-generating scan exist at all — and 9–11 are the ranked-search
work proper. Commit 1 is independent of everything after it and can be
taken on its own.
