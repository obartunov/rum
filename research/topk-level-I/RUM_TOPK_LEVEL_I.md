# Top-K indexability, level I: making LIMIT reduce exact ranking

Base: `obartunov/rum` `ranked` at `ad66f3b`, PostgreSQL 20devel source
`e073b64`, `--enable-cassert`. Research stand only — no patch is
proposed here and nothing below is on the published branch.

## Result

For a BM25 ordering with `LIMIT 10`, the number of exact ranking
operations fell from 20 000 to 4 021 with a byte-identical top 10.

    baseline, rank_cd ordering
        LIMIT 10 / 100 / 1000      exact rank = 20000 in every case

    BM25 ordering, same corpus
        without pruning   L=10     exact = 20000
        with pruning      L=10     exact =  4021   pruned = 15979
        with pruning      L=100    exact =  4194   pruned = 15806

    violations = 0    wrong = 0
    top-10 md5 identical before and after

This is the first time `LIMIT` has changed how much ranking work RUM
does. Before this, `LIMIT` 10, 100 and 1000 all produced exactly 20 000
ranking calls.

## The chain that had to be built

Five links, each of which turned out to be missing:

    LIMIT k in the executor
        |  ExecSetTupleBound recurses into 8 node types, no scan among them
        v
    k reaches the index AM              <- new field + bridge
        |
        v
    bounded heap in the sort            <- two core bugs, below
        |
        v
    current cutoff readable             <- new core accessor
        |
        v
    cheap optimistic bound              <- derived per ranking function
        |
        v
    skip exact rank

### 1. k reaches the AM

`compute_tuples_needed()` in `nodeLimit.c` is `count + offset`, and `-1`
for `LIMIT ALL` and `WITH TIES`. `ExecSetTupleBound` descends into Sort,
IncrementalSort, Append, MergeAppend, Result, SubqueryScan, Gather and
GatherMerge — **no scan node**, so the bound stops one level above every
index scan. `IndexScanDescData` has no field for it and no AM knows the
concept.

Added `xs_tuples_needed` to the scan descriptor, `iss_TuplesNeeded` to
`IndexScanState` (the bound can be set before the descriptor exists), and
a branch in `ExecSetTupleBound`. Measured at the AM:

| query | k seen |
|---|---|
| `LIMIT 10` | 10 |
| `LIMIT 10 OFFSET 100` | **110** |
| parameterized `LIMIT $1` executed with 25 | 25 |
| no `LIMIT`, `LIMIT ALL`, `WITH TIES` | −1 |
| filter, join or subquery qual above the scan | −1 |
| volatile function in the target list | 10 |

The first three of the last two rows stop by themselves — the recursion
never reaches the scan. The volatile case does not stop it, correctly:
the scan still returns the same rows in the same order.

### 2. Two core bugs in bounded sort

RUM's ordered scan sorts through its own `comparetup` and has no
`SortSupport`. `tuplesort_set_bound()` accepts that and then segfaults:

- it writes `state->base.sortKeys->abbrev_converter = NULL` unguarded;
- `make_bounded_heap()` calls `reversedirection()`, which walks
  `sortKeys`.

Confirmed by instrument, not by reading: `nKeys=1 sortKeys=(nil)` at the
call, then SIGSEGV. Stock `ORDER BY ... LIMIT` is unaffected because
every core variant has `sortKeys`; RUM is the first consumer without one.

The requirement is written nowhere — no assert, no comment.  Worked
around here by guarding the abbreviated-key reset, adding a
`reversedirection` callback next to `comparetup`, and declining the bound
when a variant offers neither.

Stated carefully, since none of this has been raised upstream: **bounded
tuplesort currently assumes SortSupport/sortKeys in paths where a
comparetup-only variant can otherwise exist.**  Whether that is a defect
or an undocumented precondition is for the list to say.  The attached
diff is evidence and a proof of concept, not a patch submission.

### 3. Cutoff

`tuplesort_get_bounded_root()` returns `memtuples[0].datum1` by value,
and false unless `TSS_BOUNDED`. Measured: the bounded heap is built after
`2k + 1` candidates, so the cutoff is unavailable for the first 21 of
20 000 at `k = 10` — the counter reports that separately rather than
mixing it with "the bound did not fire".

## Three ranking functions, three different answers

### rank_cd — the shipped `<=>`

Cost decomposition first, corrected for a 57.7 ns instrument:

| shape | ranking | DocRep build | its sort | `calc_score_docr` | ranking share |
|---|---|---|---|---|---|
| `a & b & c` | 205.8 ms | 7.1 ms | 42.1 ms | **159.3 ms** | 99% |
| `a \| b` | 22.9 ms | 3.4 ms | 3.1 ms | **19.1 ms** | 58% |
| phrase | 129.1 ms | 5.3 ms | 27.4 ms | **99.1 ms** | 84% |

Ranking is 58–99% of query time and the cover walk is 77–81% of ranking.

Bound derived from `calc_score_docr`: `1.64493406685` is exactly π²/6,
the limit of `Σ1/L²`, so a group of covers sharing a key sums to at most
one maximal contribution; `Cpos ≤ nitems` because `InvSum` adds one
weight per entry and the smallest weight is 1.0; covers ≤ `min_t(npos_t)`
because each cover consumes an occurrence of every operand.

    score <= min(npos) * nitems

Sound (`violations = 0` over 60 000 checks) and **useless**: it prunes
nothing, on a uniform corpus and on a corpus with positions spread 2..200
alike. The gap to the cutoff is two orders of magnitude, and it comes
from one place: the safe derivation must assume the most favourable
weight class (arrdata 1.0) while the corpus carries only weight D, where
arrdata is 10.

Counterfactually supplying that one document-level fact — the minimum
weight class among the document's query-term positions — takes pruning
from 0 to **7 992 of 19 979** on the varied corpus and leaves it at 0 on
the uniform one.

That figure comes from **virtual document/entry information, not a
production storage design**.  It says that *some* document-level summary
makes this bound useful for this ranking function on this corpus.  It
does not follow that a next-generation RUM must store weight class.

### trigram — `rum_trgm_ordering`

    distance = 1 - c / (nq + nd - c)

Different information: entry-level presence only, plus document-level
`nd` already in addInfo. The bound follows from monotonicity in `c`:
assume every unprobed entry matches.

But exact ranking here is arithmetic over counts that are already known
by the time a candidate reaches the sort, so the bound degenerates to the
exact value.  It is useful only **earlier**, inside the probe loop, where
it would save probe seeks rather than ranking.  Not implemented; recorded
because of what it implies:

> a single fixed call site for `candidateBound()` is not enough.

The bound can be meaningful at a different point of candidate information
accumulation.

### BM25 — the one that worked

    score = SUM_t idf_t * tf_t * (k1+1) / (tf_t + k1 * (1 - b + b*dl/avgdl))

With `b = 0`, no document length is needed by either the score or the
bound. `f(tf) = idf*tf*(k1+1)/(tf+k1)` increases in `tf` with supremum
`idf*(k1+1)`, so for the terms already known to be present:

    score < SUM_{t present} idf_t * (k1 + 1)

This uses **presence only** — established by the merge — and `idf` from
`predictNumberResult`, which the scan already has. No tf, no positions,
no new payload.

A first version summed over all query terms and was useless, ratio
47 875: it credited every candidate with the rare term `gamma`
(`idf = 1.61` against `0.000025`) whether present or not. Restricting the
sum to terms known present brought the ratio to **1.55**.

Validated in SQL over the same data first (20 000 candidates,
`violations = 0`, pruned 15 980), then in the scan itself, which agreed
to within one candidate (15 979).

## Negative controls

| control | expectation | result |
|---|---|---|
| uniform corpus, rank_cd bound | no discrimination | pruned 0 |
| uniform document length, BM25 | weaker bound | pruned 15 960 vs 15 980 |
| no cutoff yet (first 2k+1) | exact rank | counted separately, 21 |
| bound unavailable | exact rank | invariant, never violated |

The second is worth stating plainly: **document length barely matters for
the BM25 bound here**. I expected it to be the key, as weight class was
for rank_cd. What discriminates is which terms are present, weighted by
idf. `dl` is needed for an exact BM25 score, not for a useful bound.

## What this says about the API

The shape `candidate information → BOUND → RANK` held on two functions
with different mathematics and different inputs. Three corrections to the
`candidateConsistent / candidateBound / candidateRank` triple:

**A term-global channel is required.** The BM25 bound is built on `idf`,
a property of the collection and the query, not of the candidate. Without
it the bound does not exist. The triple has no such input.

**There is no single call site.** rank_cd wants the bound after matching;
trigram inside the probe loop; BM25 after presence is known but before
`tf` is read. `candidateBound` has to be callable as evidence
accumulates — the incremental acquisition that was in the indexability
sketch and fell out of the proposed API.

**The bound must be able to answer "unavailable".** Already an invariant
here: no cutoff or no bound means exact ranking. It is what allowed
pruning to be switched on only after `violations = 0`, and it held in
every run.

## Scope and honesty

- The ordering is replaced by BM25 under `-DRUM_BM25_EXPERIMENT` so that
  the existing machinery runs unchanged; `<=>` computes BM25 rather than
  rank_cd in that build. No SQL, operator or opclass changes.
- `BM25_N` is the constant 20 000, not a statistic.
- The rank_cd weight-class factor is a constant 10 under
  `-DRUM_VIRTUAL_DOC_WEIGHT`, valid only because the corpus carries
  weight D throughout. It answers "what would it give", not "what it
  gives".
- Wall-clock time was not measured, only `N_exact_rank`.  No speedup is
  claimed.
- Changed: 6 files in RUM (398 lines), 7 in PostgreSQL (88 lines).

## Two process notes

Adding a field to the middle of a public struct cost most of the debugging
time, twice: `IndexScanDescData` and then `TuplesortPublic`. Both produced
memory corruption rather than a compile error — the second showed as
`TRAP: failed Assert("MemoryContextIsValid(context)")` on a plain
`ORDER BY ... LIMIT` with no RUM involved. A full rebuild did not help
and I never established why. New fields go at the very end of a public
struct; both times that fixed it with no other change.

PGXS does not rebuild when only `PG_CPPFLAGS` changes. The first run with
pruning enabled reported `exact = 20000`, which I nearly filed as "the
mechanism does not work". `make clean` is required on every flag change.
