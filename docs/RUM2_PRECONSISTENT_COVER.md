# Fixing the FTS duplicate fetch, by the other route

F1 tried to remove the duplicated fetch by merging two posting streams,
and crashed: entries carry per-key mutable state.  This takes the route
the trigram patch already uses instead, and it works.

## The observation that made it possible

The trigram reuse patch does not merge streams.  It leaves both and stops
the *ordering* side from re-reading what the match side already holds,
copying the evidence at emission.  That mechanism lives in the counting
scan, which is why it never applied to FTS: an ordered FTS query never
reaches the counting scan, because the gate demands a query minimum from
support procedure 11 and `rum_tsvector_ops` has none — and cannot have
one, since an `OR` query's minimum is 1 and the K-of-N arithmetic says
nothing.

Modern GIN does not use arithmetic for this.  `startScanKey`
(`ginget.c:519-602`) sorts entries by predicted frequency and grows the
required set until the opclass's own tri-state consistent reports that no
match survives without it.  RUM has the same capability already, as
`preConsistentFn`.

## The change

Behind `rum.preconsistent_cover`:

- the counting gate admits a search key with no query minimum, provided
  the opclass has `preConsistent` and there is more than one entry;
- the cover is then derived, not computed: entries are already sorted
  least frequent first, and the cover is the smallest prefix whose
  complete absence makes `preConsistent` report no possible match.  A row
  missing all of them cannot match, so merging just those still produces
  every candidate.  The loop terminates because with every entry absent
  the answer must be negative;
- with no integer bound available, `needed` is 1, so no candidate is ever
  rejected by counting.  `consistent()` decides, exactly as before.

Nothing about ranking changed.  The gain comes from the counting scan
treating the order-by key's entries as sync entries, at which point the
existing evidence-reuse patch applies to FTS unmodified.

## Result

`foo & bar & alpha`, 20 000 documents, ordered by `<=>`:

    cover derived      3 entries -> 1 generator, 2 probes   (correct for AND)
    sync seeks         gone
    order-by entries advanced at emission   60 000 -> 0
    duplicate addInfo fetches               60 000 -> 0

Warm median of 5, ordered FTS queries:

| query | baseline | preConsistent cover | |
|---|---|---|---|
| `foo & bar & alpha` | 35.7 ms | 27.9 ms | −22% |
| `phraseto('foo qux bar')` | 31.3 ms | 26.7 ms | −15% |
| `(foo & bar) \| (epsilon & alpha)` | 39.2 ms | 29.4 ms | −25% |

Correctness: the thirteen-case FTS and addon matrix is identical to
baseline in TID sequence and rank bytes, including phrase, weights,
`AND/OR/NOT`, full output, `q1 <> q2` and all three addon operators.  The
full suite passes with the flag off and with it on by default, 37/37 +
2/2 on PG20 with `--enable-cassert`.

## What is still duplicated

Decoding.  `matchDecodes` and `rankDecodes` are both still 60 000: the
positions are fetched once now but unpacked twice, once by
`checkcondition_rum` for `@@` and once by the ranking.  That is F2, and it
needs an owner for the decoded representation — the thing this change
deliberately does not touch.

So the split the earlier measurement suggested holds, and the cheaper
half is done: **the duplicate fetch was removable, the duplicate decode
is a separate problem.**

## Status and caveats

Research branch, flag defaults off in the committed state.  This widens
the counting-scan gate, which is precisely where a narrow gate saved us
from a silent zero-rows bug on addon ordering; the addon cases are in the
matrix above and pass, but the same care is owed to any further widening.
Partial-match entries remain excluded by the existing entry check.

Measured on one corpus of 20 000 short documents.  The trigram numbers
elsewhere in this work come from 200 000 rows; these do not, and the two
should not be compared.
