/*-------------------------------------------------------------------------
 *
 * rum_trgm.c
 *		Trigram similarity opclass for RUM.
 *
 * Each indexed value contributes one entry per trigram, with the value's
 * trigram count stored as addInfo.  That count is a document-level
 * property identical in every posting of one indexed row, which is what
 * RUM_CANDIDATE_MIN_MATCHES_PROC requires: knowing it, the scan names the
 * exact minimal overlap this row needs to reach the similarity threshold
 * and can reject the candidate right after its first posting, before
 * touching any frequent trigram.  The overlap is exact, so consistent()
 * reports recheck = false and ordering() answers <-> directly.
 *
 * Trigram extraction here must agree with pg_trgm byte for byte: the
 * heap-side operators are pg_trgm's, and with recheck = false a
 * divergence would silently produce wrong answers rather than a slower
 * plan.  pg_trgm offers no C-level entry point -- generate_trgm is absent
 * from the dynamic symbol table of pg_trgm.so -- and resolving show_trgm
 * by name fails inside CREATE INDEX, which has run under
 * RestrictSearchPath() since PG 17.  So this file reimplements the
 * *output format*, which on-disk compatibility of existing pg_trgm
 * indexes keeps stable, rather than copying the current internals, which
 * upstream has reorganized more than once:
 *
 *		words are maximal runs of alphanumeric characters
 *		each word is case-folded under the default collation
 *		each word is padded with 2 leading and 1 trailing space
 *		trigrams are 3 consecutive characters of the padded word
 *		a trigram of single-byte characters is stored as those 3 bytes
 *		any other trigram is stored as 3 bytes of its legacy CRC-32
 *		the result is sorted bytewise and deduplicated
 *
 * The equality is enforced by test, not by inspection: rum_trgm_show()
 * exposes this extraction so the regression suite can compare it with
 * pg_trgm's show_trgm() over a corpus, hand-picked edge cases and
 * randomly generated strings.
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include <ctype.h>
#include <math.h>

#include "access/stratnum.h"
#include "catalog/pg_collation.h"
#include "catalog/pg_type.h"
#include "fmgr.h"
#include "mb/pg_wchar.h"
#include "tsearch/ts_locale.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/formatting.h"
#include "utils/guc.h"
#include "utils/pg_crc.h"

#include "rum.h"

/* Mirrors of pg_trgm's compile-time settings; see contrib/pg_trgm/trgm.h */
#define RUM_TRGM_LPADDING	2
#define RUM_TRGM_RPADDING	1

/* pg_trgm strategy numbers we answer */
#define RumTrgmSimilarityStrategy	1
#define RumTrgmDistanceStrategy		20

typedef char rum_trgm[3];

#define RUM_CPTRGM(a, b) \
	do { \
		*(((char *) (a)) + 0) = *(((char *) (b)) + 0); \
		*(((char *) (a)) + 1) = *(((char *) (b)) + 1); \
		*(((char *) (a)) + 2) = *(((char *) (b)) + 2); \
	} while (0)

#define RUM_ISPRINTABLECHAR(a) \
	(isascii(*(unsigned char *) (a)) && \
	 (isalnum(*(unsigned char *) (a)) || *(unsigned char *) (a) == ' '))
#define RUM_ISPRINTABLETRGM(t) \
	(RUM_ISPRINTABLECHAR((char *) (t)) && \
	 RUM_ISPRINTABLECHAR(((char *) (t)) + 1) && \
	 RUM_ISPRINTABLECHAR(((char *) (t)) + 2))

PG_FUNCTION_INFO_V1(rum_trgm_cmp);
PG_FUNCTION_INFO_V1(rum_trgm_extract_value);
PG_FUNCTION_INFO_V1(rum_trgm_extract_query);
PG_FUNCTION_INFO_V1(rum_trgm_consistent);
PG_FUNCTION_INFO_V1(rum_trgm_config);
PG_FUNCTION_INFO_V1(rum_trgm_ordering);
PG_FUNCTION_INFO_V1(rum_trgm_query_min_matches);
PG_FUNCTION_INFO_V1(rum_trgm_candidate_min_matches);
PG_FUNCTION_INFO_V1(rum_trgm_show);

/*
 * The threshold is pg_trgm's, not ours.  A second GUC would let the index
 * and the heap-side % operator disagree while consistent() reports
 * recheck = false, which loses rows silently, so read pg_trgm's own
 * setting.  It is a hash lookup, paid once per scan in the query-level
 * bound and once per distinct document size in the candidate bound, since
 * RUM memoizes that.
 */
static double
rum_trgm_threshold(void)
{
	const char *val;

	val = GetConfigOption("pg_trgm.similarity_threshold", true, false);
	if (val == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_OBJECT),
				 errmsg("rum_trgm requires the pg_trgm extension to be loaded"),
				 errdetail("The setting pg_trgm.similarity_threshold is not defined.")));

	return strtod(val, NULL);
}

/* Length of the character at p, never reading past end. */
static inline int
rum_trgm_mblen(const char *p, const char *end)
{
	int			len = pg_mblen(p);

	return Min(len, (int) (end - p));
}

/*
 * Locate the next maximal run of word characters in [str, str + lenstr).
 * Returns its start and sets *endword just past its last byte, or NULL
 * when the range holds no word character.
 */
static char *
rum_trgm_find_word(char *str, int lenstr, char **endword)
{
	char	   *beginword = str;
	char	   *endstr = str + lenstr;

	while (beginword < endstr)
	{
		int			clen = rum_trgm_mblen(beginword, endstr);

		if (t_isalnum(beginword))
			break;
		beginword += clen;
	}

	if (beginword >= endstr)
		return NULL;

	*endword = beginword;
	while (*endword < endstr)
	{
		int			clen = rum_trgm_mblen(*endword, endstr);

		if (!t_isalnum(*endword))
			break;
		*endword += clen;
	}

	return beginword;
}

/*
 * Reduce one trigram, which may span multibyte characters, to three
 * bytes: the characters themselves when all three are single-byte,
 * otherwise three bytes of the legacy CRC-32 of the whole trigram.
 */
static void
rum_trgm_compact(rum_trgm *tptr, char *str, int bytelen)
{
	if (bytelen == 3)
		RUM_CPTRGM(tptr, str);
	else
	{
		pg_crc32	crc;

		INIT_LEGACY_CRC32(crc);
		COMP_LEGACY_CRC32(crc, str, bytelen);
		FIN_LEGACY_CRC32(crc);
		RUM_CPTRGM(tptr, &crc);
	}
}

/*
 * Append the trigrams of one already padded word.  *ntrgms is the current
 * length of *trgms, *maxtrgms its capacity.
 */
static void
rum_trgm_make(rum_trgm **trgms, int *ntrgms, int *maxtrgms,
			  char *str, int bytelen)
{
	char	   *ptr = str;
	char	   *endstr = str + bytelen;

	if (bytelen < 3)
		return;

	/* at most bytelen - 2 trigrams come out of this word */
	if (*ntrgms + (bytelen - 2) > *maxtrgms)
	{
		*maxtrgms = Max(*maxtrgms * 2, *ntrgms + bytelen - 2);
		*trgms = (rum_trgm *) repalloc(*trgms, sizeof(rum_trgm) * *maxtrgms);
	}

	if (pg_database_encoding_max_length() == 1)
	{
		while (ptr < endstr - 2)
		{
			RUM_CPTRGM(&(*trgms)[*ntrgms], ptr);
			(*ntrgms)++;
			ptr++;
		}
	}
	else
	{
		int			lenfirst,
					lenmiddle,
					lenlast;
		char	   *endptr;

		lenfirst = rum_trgm_mblen(ptr, endstr);
		if (ptr + lenfirst >= endstr)
			return;
		lenmiddle = rum_trgm_mblen(ptr + lenfirst, endstr);
		if (ptr + lenfirst + lenmiddle >= endstr)
			return;
		lenlast = rum_trgm_mblen(ptr + lenfirst + lenmiddle, endstr);

		endptr = ptr + lenfirst + lenmiddle + lenlast;
		while (endptr <= endstr)
		{
			rum_trgm_compact(&(*trgms)[*ntrgms], ptr, endptr - ptr);
			(*ntrgms)++;

			if (endptr == endstr)
				break;
			ptr += lenfirst;
			lenfirst = lenmiddle;
			lenmiddle = lenlast;
			lenlast = rum_trgm_mblen(endptr, endstr);
			endptr += lenlast;
		}
	}
}

static int
rum_trgm_bytecmp(const void *a, const void *b)
{
	return memcmp(a, b, 3);
}

/*
 * Extract the sorted, deduplicated trigram set of a string.
 */
static rum_trgm *
rum_trgm_generate(char *str, int slen, int *ntrgms)
{
	rum_trgm   *trgms;
	int			n = 0,
				maxtrgms;
	size_t		buflen;
	char	   *buf;
	char	   *bword,
			   *eword;
	int			i,
				j;

	*ntrgms = 0;

	if (slen <= 0 || slen + RUM_TRGM_LPADDING + RUM_TRGM_RPADDING < 3)
		return NULL;

	maxtrgms = slen + 3;
	trgms = (rum_trgm *) palloc(sizeof(rum_trgm) * maxtrgms);

	buflen = (size_t) slen + 4;
	buf = (char *) palloc(buflen);
	buf[0] = ' ';
	buf[1] = ' ';

	eword = str;
	while ((bword = rum_trgm_find_word(eword, slen - (eword - str),
									   &eword)) != NULL)
	{
		char	   *lowered;
		int			bytelen;

		lowered = str_tolower(bword, eword - bword, DEFAULT_COLLATION_OID);
		bytelen = strlen(lowered);

		/* case folding may lengthen the word */
		if ((size_t) bytelen > buflen - 4)
		{
			pfree(buf);
			buflen = (size_t) bytelen + 4;
			buf = (char *) palloc(buflen);
			buf[0] = ' ';
			buf[1] = ' ';
		}

		memcpy(buf + RUM_TRGM_LPADDING, lowered, bytelen);
		pfree(lowered);

		buf[RUM_TRGM_LPADDING + bytelen] = ' ';
		buf[RUM_TRGM_LPADDING + bytelen + 1] = ' ';

		rum_trgm_make(&trgms, &n, &maxtrgms, buf,
					  bytelen + RUM_TRGM_LPADDING + RUM_TRGM_RPADDING);
	}

	pfree(buf);

	if (n == 0)
	{
		pfree(trgms);
		return NULL;
	}

	qsort(trgms, n, sizeof(rum_trgm), rum_trgm_bytecmp);

	/* deduplicate in place */
	for (i = 0, j = 1; j < n; j++)
	{
		if (memcmp(trgms[i], trgms[j], 3) != 0)
		{
			i++;
			if (i != j)
				RUM_CPTRGM(trgms[i], trgms[j]);
		}
	}

	*ntrgms = i + 1;
	return trgms;
}

/* Render one trigram the way pg_trgm's show_trgm() does. */
static text *
rum_trgm_to_text(rum_trgm *ptr)
{
	text	   *item;

	item = (text *) palloc(VARHDRSZ +
						   Max(12, pg_database_encoding_max_length() * 3));

	if (pg_database_encoding_max_length() > 1 && !RUM_ISPRINTABLETRGM(ptr))
	{
		/* same big-endian composition as pg_trgm's trgm2int() */
		snprintf(VARDATA(item), 12, "0x%06x",
				 (unsigned int) ((((uint8) (*ptr)[0]) << 16) |
								 (((uint8) (*ptr)[1]) << 8) |
								 ((uint8) (*ptr)[2])));
		SET_VARSIZE(item, VARHDRSZ + strlen(VARDATA(item)));
	}
	else
	{
		SET_VARSIZE(item, VARHDRSZ + 3);
		RUM_CPTRGM(VARDATA(item), ptr);
	}

	return item;
}

/*
 * Test entry point: the trigram set of a value, in the representation
 * pg_trgm's show_trgm() produces.  Declared by the regression fixture,
 * not by the extension script.
 */
Datum
rum_trgm_show(PG_FUNCTION_ARGS)
{
	text	   *in = PG_GETARG_TEXT_PP(0);
	rum_trgm   *trgms;
	int			n,
				i;
	Datum	   *d;
	ArrayType  *a;

	trgms = rum_trgm_generate(VARDATA_ANY(in), VARSIZE_ANY_EXHDR(in), &n);

	d = (Datum *) palloc(sizeof(Datum) * Max(n, 1));
	for (i = 0; i < n; i++)
		d[i] = PointerGetDatum(rum_trgm_to_text(&trgms[i]));

	a = construct_array(d, n, TEXTOID, -1, false, TYPALIGN_INT);

	PG_RETURN_POINTER(a);
}

/* FUNCTION 1: bytewise comparison of two trigram keys */
Datum
rum_trgm_cmp(PG_FUNCTION_ARGS)
{
	text	   *a = PG_GETARG_TEXT_PP(0);
	text	   *b = PG_GETARG_TEXT_PP(1);
	int			lena = VARSIZE_ANY_EXHDR(a),
				lenb = VARSIZE_ANY_EXHDR(b);
	int			res;

	res = memcmp(VARDATA_ANY(a), VARDATA_ANY(b), Min(lena, lenb));
	if (res == 0)
		res = (lena < lenb) ? -1 : ((lena > lenb) ? 1 : 0);

	PG_FREE_IF_COPY(a, 0);
	PG_FREE_IF_COPY(b, 1);
	PG_RETURN_INT32(res);
}

/*
 * FUNCTION 2: trigrams of an indexed value, plus the document-level
 * addInfo every entry of this row carries: the row's trigram count.
 */
Datum
rum_trgm_extract_value(PG_FUNCTION_ARGS)
{
	text	   *val = PG_GETARG_TEXT_PP(0);
	int32	   *nentries = (int32 *) PG_GETARG_POINTER(1);
	Datum	  **addInfo = (Datum **) PG_GETARG_POINTER(3);
	bool	  **addInfoIsNull = (bool **) PG_GETARG_POINTER(4);
	rum_trgm   *trgms;
	int			n,
				i;
	Datum	   *entries;

	trgms = rum_trgm_generate(VARDATA_ANY(val), VARSIZE_ANY_EXHDR(val), &n);
	*nentries = n;

	entries = (Datum *) palloc(sizeof(Datum) * Max(n, 1));
	*addInfo = (Datum *) palloc(sizeof(Datum) * Max(n, 1));
	*addInfoIsNull = (bool *) palloc(sizeof(bool) * Max(n, 1));

	for (i = 0; i < n; i++)
	{
		entries[i] = PointerGetDatum(rum_trgm_to_text(&trgms[i]));
		(*addInfo)[i] = Int32GetDatum(n);
		(*addInfoIsNull)[i] = false;
	}

	PG_RETURN_POINTER(entries);
}

/* FUNCTION 3: trigrams of the query string */
Datum
rum_trgm_extract_query(PG_FUNCTION_ARGS)
{
	text	   *val = PG_GETARG_TEXT_PP(0);
	int32	   *nentries = (int32 *) PG_GETARG_POINTER(1);
	int32	   *searchMode = (int32 *) PG_GETARG_POINTER(6);
	rum_trgm   *trgms;
	int			n,
				i;
	Datum	   *entries;

	trgms = rum_trgm_generate(VARDATA_ANY(val), VARSIZE_ANY_EXHDR(val), &n);
	*nentries = n;

	entries = (Datum *) palloc(sizeof(Datum) * Max(n, 1));
	for (i = 0; i < n; i++)
		entries[i] = PointerGetDatum(rum_trgm_to_text(&trgms[i]));

	if (n == 0)
		*searchMode = GIN_SEARCH_MODE_ALL;

	PG_RETURN_POINTER(entries);
}

/*
 * Exact similarity: pg_trgm's DIVUNION formula over the overlap count,
 * the query size and the document size taken from addInfo.
 */
static double
rum_trgm_similarity(int32 overlap, int32 nquery, int32 ndoc)
{
	int32		unionsize = nquery + ndoc - overlap;

	if (unionsize <= 0)
		return 0.0;
	return (double) overlap / (double) unionsize;
}

/* Smallest overlap a document of ndoc trigrams needs to reach threshold */
static int32
rum_trgm_min_overlap(int32 nquery, int32 ndoc, double threshold)
{
	double		x;
	int32		need;

	if (nquery <= 0 || ndoc <= 0)
		return nquery > 0 ? nquery : 0;

	/*
	 * c / (nquery + ndoc - c) >= t  <=>  c >= t * (nquery + ndoc) / (1 + t)
	 */
	x = threshold * (double) (nquery + ndoc) / (1.0 + threshold);
	need = (int32) ceil(x - 1e-9);

	if (need < 1)
		need = 1;
	return need;
}

/* FUNCTION 4: exact similarity; never asks for a heap recheck */
Datum
rum_trgm_consistent(PG_FUNCTION_ARGS)
{
	bool	   *check = (bool *) PG_GETARG_POINTER(0);
	StrategyNumber strategy = PG_GETARG_UINT16(1);
	int32		nkeys = PG_GETARG_INT32(3);
	bool	   *recheck = (bool *) PG_GETARG_POINTER(5);
	Datum	   *addInfo = (Datum *) PG_GETARG_POINTER(8);
	bool	   *addInfoIsNull = (bool *) PG_GETARG_POINTER(9);
	int32		i,
				overlap = 0,
				ndoc = 0;

	*recheck = false;

	for (i = 0; i < nkeys; i++)
	{
		if (!check[i])
			continue;
		overlap++;
		if (ndoc == 0 && !addInfoIsNull[i])
			ndoc = DatumGetInt32(addInfo[i]);
	}

	if (strategy != RumTrgmSimilarityStrategy || overlap == 0 || ndoc == 0)
		PG_RETURN_BOOL(false);

	PG_RETURN_BOOL(rum_trgm_similarity(overlap, nkeys, ndoc) >=
				   rum_trgm_threshold());
}

/* FUNCTION 6: addInfo is an int4 carried with every entry */
Datum
rum_trgm_config(PG_FUNCTION_ARGS)
{
	RumConfig  *config = (RumConfig *) PG_GETARG_POINTER(0);

	config->addInfoTypeOid = INT4OID;
	config->strategyInfo[0].strategy = InvalidStrategy;

	PG_RETURN_VOID();
}

/* FUNCTION 8: distance for ORDER BY t <-> q, i.e. 1 - similarity */
Datum
rum_trgm_ordering(PG_FUNCTION_ARGS)
{
	bool	   *check = (bool *) PG_GETARG_POINTER(0);
	int32		nkeys = PG_GETARG_INT32(3);
	Datum	   *addInfo = (Datum *) PG_GETARG_POINTER(8);
	bool	   *addInfoIsNull = (bool *) PG_GETARG_POINTER(9);
	int32		i,
				overlap = 0,
				ndoc = 0;

	for (i = 0; i < nkeys; i++)
	{
		if (!check[i])
			continue;
		overlap++;
		if (ndoc == 0 && !addInfoIsNull[i])
			ndoc = DatumGetInt32(addInfo[i]);
	}

	if (overlap == 0 || ndoc == 0)
		PG_RETURN_FLOAT8(1.0);

	PG_RETURN_FLOAT8(1.0 - rum_trgm_similarity(overlap, nkeys, ndoc));
}

/*
 * FUNCTION 11: query-level lower bound.  Any row reaching the threshold
 * shares at least this many trigrams with the query, whatever its size,
 * since the union is at least the query size.
 */
Datum
rum_trgm_query_min_matches(PG_FUNCTION_ARGS)
{
	StrategyNumber strategy = PG_GETARG_UINT16(1);
	int32		nentries = PG_GETARG_INT32(2);
	int32		need;

	if (strategy != RumTrgmSimilarityStrategy || nentries <= 0)
		PG_RETURN_INT32(0);

	need = (int32) ceil(rum_trgm_threshold() * (double) nentries - 1e-9);
	if (need < 1)
		need = 1;
	if (need > nentries)
		need = nentries;

	PG_RETURN_INT32(need);
}

/*
 * FUNCTION 12: candidate-level refinement.  With the document's trigram
 * count from addInfo the minimal overlap is exact, and it never falls
 * below the query-level bound.
 */
Datum
rum_trgm_candidate_min_matches(PG_FUNCTION_ARGS)
{
	StrategyNumber strategy = PG_GETARG_UINT16(1);
	int32		nentries = PG_GETARG_INT32(2);
	int32		ndoc = PG_GETARG_INT32(3);
	int32		need;

	if (strategy != RumTrgmSimilarityStrategy || nentries <= 0)
		PG_RETURN_INT32(0);

	need = rum_trgm_min_overlap(nentries, ndoc, rum_trgm_threshold());
	if (need > nentries)
		need = nentries;

	PG_RETURN_INT32(need);
}
