/* rum_trgm--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION rum_trgm" to load this file. \quit

CREATE FUNCTION rum_trgm_cmp(text, text)
RETURNS int4
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION rum_trgm_extract_value(text, internal, internal, internal, internal)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION rum_trgm_extract_query(text, internal, int2, internal, internal, internal, internal)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION rum_trgm_consistent(internal, int2, text, int4, internal, internal, internal, internal)
RETURNS bool
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION rum_trgm_config(internal)
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION rum_trgm_ordering(internal, int2, text, int4, internal, internal, internal, internal, internal)
RETURNS float8
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION rum_trgm_query_min_matches(text, int2, int4)
RETURNS int4
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION rum_trgm_candidate_min_matches(text, int2, int4, int4)
RETURNS int4
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

/*
 * Not declared DEFAULT: within the rum access method the default opclass
 * for text is already rum_text_ops, so an index names this one
 * explicitly, as USING rum (col rum_trgm_ops).
 */
CREATE OPERATOR CLASS rum_trgm_ops
FOR TYPE text USING rum
AS
	OPERATOR	1	% (text, text),
	OPERATOR	20	<-> (text, text) FOR ORDER BY pg_catalog.float_ops,
	FUNCTION	1	rum_trgm_cmp(text, text),
	FUNCTION	2	rum_trgm_extract_value(text, internal, internal, internal, internal),
	FUNCTION	3	rum_trgm_extract_query(text, internal, int2, internal, internal, internal, internal),
	FUNCTION	4	rum_trgm_consistent(internal, int2, text, int4, internal, internal, internal, internal),
	FUNCTION	6	rum_trgm_config(internal),
	FUNCTION	8	rum_trgm_ordering(internal, int2, text, int4, internal, internal, internal, internal, internal),
	FUNCTION	11	rum_trgm_query_min_matches(text, int2, int4),
	FUNCTION	12	rum_trgm_candidate_min_matches(text, int2, int4, int4),
	STORAGE		text;
