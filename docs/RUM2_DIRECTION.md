# Direction for a next-generation RUM

**The next-generation RUM starts from current PostgreSQL GIN, not from
the current RUM code base.**

This is a decision about where the code comes from, not a deprecation.
The RUM in this repository continues as it is.

## Why GIN is the trunk

Current GIN already provides what a search access method needs below the
search logic, and what a fork of the current RUM would have to keep
re-synchronising:

- mature posting list and posting tree storage
- WAL and recovery
- VACUUM
- fastupdate
- parallel build
- required and additional entries, chosen by predicted frequency
- `triConsistent`
- candidate-aware matching

The last three matter more than they look. `startScanKey()` already
grows a required set until the opclass's tri-state consistent says no
match survives without it, and turns the rest into entries probed
lazily. Generators and probes are not something a new RUM has to invent.

What GIN does not have, and a search access method needs:

- generic candidate information beyond `key -> TID`
- ordered tuple retrieval (`amgettuple` is NULL, `amcanorderbyop` false)
- incremental top-K reasoning
- ranking-specific safe bounds
- exact ranking only where it can change the answer

## What the current RUM is for

- **algorithm donor** — addInfo semantics, ordered scan, distance and
  ranking ideas
- **semantics and opclass donor** — twenty years of what the operators
  must mean
- **regression corpus** — see below
- **experimental laboratory** — the Top-K Level I work was done here
  precisely because it is cheaper to experiment in

But **not the implementation base for the next-generation RUM.**

## Two levels of top-K indexability

    Level I
    -------
    candidate is visited
    a cheap bound may avoid exact ranking

    reduces:  N_exact_rank

    Level II
    --------
    a region -- posting block, segment, subtree -- carries a bound
    a hopeless region is not visited at all

    reduces:  candidates, posting work, pages read

Level I has been demonstrated: see
`research/topk-level-I/RUM_TOPK_LEVEL_I.md`, where a BM25 ordering with
`LIMIT 10` goes from 20 000 exact rankings to 4 021 with an identical top
10.

**Level II is not implemented.** It requires statistics stored per region
and is the point at which storage format enters the picture. It should
not be conflated with the Level I result.

## The shape of the decision loop

Not this:

    MATCH -> BOUND -> RANK

The experiments contradict it. rank_cd wants a bound after matching;
trigram only earlier, inside the probe loop; BM25 after term presence is
known but before `tf` is read. The general shape is:

    candidate
        |
    accumulate information
        |
    ask whether more work can change the result
        |
        +-- reject candidate
        +-- prune from top-K
        +-- need more information
        +-- exact rank

A bound is therefore:

- ranking-specific;
- able to appear at different stages;
- able to return `UNKNOWN`;
- safe, meaning optimistic with respect to the ordering — it must never
  claim a candidate is worse than it may turn out to be;
- never a licence to prune on insufficient information.

The invariant:

> **UNKNOWN or unavailable bound → do the exact work. Never guess.**

## Information channels

Logical channels, not an on-disk format — that comes later, and only
once it is known what has to be stored:

    entry-local information
        properties of a term occurrence in a candidate

    document-local information
        properties of the document

    term / query / global information
        df, idf, collection statistics, query parameters

The BM25 experiment needed the third channel and no new storage at all;
rank_cd needed the second; trigram needed the second in a form it already
has. The access method must not understand any of it.

> The ranking function may be anything. The access method must not know
> what `tf`, positions, BM25, `rank_cd` or weights mean. That is the
> responsibility of the opclass and its ranking implementation.

## Two principles

> **Acquire only the information needed for the next decision.**

> **A correct bound is not necessarily a useful bound.**

The second is not a slogan. The first safe bound derived for `rank_cd`
had `violations = 0` and `pruned = 0`: provably correct, and it never
avoided a single exact ranking.

## Regression donor

When work moves to a GIN fork, the current RUM is the source of test
cases that already caught real defects. Carried over by meaning, not
mechanically:

- VACUUM corner cases
- empty posting tree after all postings are removed
- ordered scans
- addInfo behaviour
- opclass semantics
- historical bug regressions

`sql/rum_vacuum.sql`, added with the fix for the segfault reported as
issue #183, is the concrete example: it fails when that fix is reverted,
and it covers a fully emptied posting tree through more than one scan
mode. No promise is made to port the whole suite mechanically.

## PostgreSQL-side findings

Two things found on the way belong to PostgreSQL rather than to this
architecture, and are kept as separate lines of work:

- **tuple bound reaching the access method.** `ExecSetTupleBound`
  descends into eight node types and no scan is among them, so `LIMIT`
  never reaches an index AM. This is generic; a btree or GiST kNN scan
  would benefit identically.
- **bounded tuplesort without SortSupport.** Bounded sort currently
  assumes `SortSupport`/`sortKeys` in paths where a comparetup-only
  variant can otherwise exist.

Neither has been raised upstream. `research/topk-level-I/` carries the
proof-of-concept diffs as evidence, not as patch submissions.
