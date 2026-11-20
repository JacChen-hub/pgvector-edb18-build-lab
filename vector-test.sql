\set ON_ERROR_STOP on
\if :seed
CREATE EXTENSION vector;
CREATE TABLE vector_test (id bigint PRIMARY KEY, embedding vector(3));
INSERT INTO vector_test VALUES (1, '[1,2,3]'), (2, '[4,5,6]'), (3, '[3,1,2]'), (4, NULL);
INSERT INTO vector_test
SELECT i, ARRAY[
    12 + (i * 127 % 10007)::real / 397,
    12 + (i * 211 % 10009)::real / 449,
    12 + (i * 263 % 10037)::real / 503
]::vector FROM generate_series(5, 10004) AS g(i);
CREATE INDEX vector_test_hnsw_idx ON vector_test
    USING hnsw (embedding vector_l2_ops) WITH (m = 16, ef_construction = 64);
\endif
ANALYZE vector_test;
SET hnsw.ef_search = 400;

DO $checks$
DECLARE ids bigint[];
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'vector') IS DISTINCT FROM '0.8.7'
       OR (SELECT count(*) FROM vector_test) <> 10004
       OR (SELECT count(embedding) FROM vector_test) <> 10003
       OR (SELECT embedding::text FROM vector_test WHERE id = 1) IS DISTINCT FROM '[1,2,3]'
       OR (SELECT embedding <-> '[3,1,2]'::vector FROM vector_test WHERE id = 4) IS NOT NULL
       OR ('[1,0,0]'::vector <=> '[0,1,0]'::vector) IS DISTINCT FROM 1.0::float8
       OR ('[1,2,3]'::vector <#> '[3,1,2]'::vector) IS DISTINCT FROM -11.0::float8
       OR abs(('[1,2,3]'::vector <-> '[3,1,2]'::vector) - sqrt(6.0::float8)) > 1e-12 THEN
        RAISE EXCEPTION 'Version, fixture, write/read, NULL, L2, cosine or inner product mismatch';
    END IF;
    BEGIN
        INSERT INTO vector_test VALUES (20000, '[1,2]');
        RAISE EXCEPTION 'Wrong vector dimension accepted';
    EXCEPTION WHEN data_exception THEN NULL;
    END;
    SELECT array_agg(id ORDER BY l2) INTO ids FROM (
        SELECT id, embedding <-> '[3,1,2]'::vector AS l2
        FROM vector_test WHERE id < 4 ORDER BY l2
    ) candidates;
    IF ids IS DISTINCT FROM ARRAY[3,1,2]::bigint[] THEN
        RAISE EXCEPTION 'Anchor order %', ids;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
        JOIN pg_am a ON a.oid = c.relam WHERE c.relname = 'vector_test_hnsw_idx'
        AND i.indrelid = 'vector_test'::regclass AND a.amname = 'hnsw' AND i.indisready AND i.indisvalid
    ) THEN RAISE EXCEPTION 'HNSW index is missing or invalid'; END IF;
END;
$checks$;

SELECT 'PLAN default';
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id FROM vector_test WHERE embedding IS NOT NULL ORDER BY embedding <-> '[20,20,20]'::vector LIMIT 10;
BEGIN;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;
SET LOCAL enable_indexonlyscan = off;
SELECT 'PLAN exact';
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id FROM vector_test WHERE embedding IS NOT NULL ORDER BY embedding <-> '[20,20,20]'::vector LIMIT 10;
COMMIT;
BEGIN;
SET LOCAL enable_seqscan = off;
SELECT 'PLAN HNSW';
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT id FROM vector_test WHERE embedding IS NOT NULL ORDER BY embedding <-> '[20,20,20]'::vector LIMIT 10;
COMMIT;

CREATE TEMP TABLE retrieval (point text PRIMARY KEY, ids bigint[], distances float8[], hits integer);
DO $compare$
DECLARE
    p text;
    q text;
    ranked text;
    plan jsonb;
    exact_ids bigint[];
    found_ids bigint[];
    exact_d float8[];
    found_d float8[];
    hits integer;
    started timestamptz;
    exact_ms numeric;
    ann_ms numeric;
BEGIN
    FOREACH p IN ARRAY ARRAY['[3,1,2]', '[20,20,20]', '[31,23,29]'] LOOP
        q := format('SELECT id, embedding <-> %L::vector AS l2 FROM vector_test WHERE embedding IS NOT NULL ORDER BY l2 LIMIT 10', p);
        ranked := 'SELECT array_agg(id ORDER BY l2,id), array_agg(l2 ORDER BY l2,id) FROM (' || q || ') s';
        PERFORM set_config('enable_seqscan','on',true);
        PERFORM set_config('enable_indexscan','off',true);
        PERFORM set_config('enable_bitmapscan','off',true);
        PERFORM set_config('enable_indexonlyscan','off',true);
        EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
        IF NOT jsonb_path_exists(plan, '$.**."Node Type" ? (@ == "Seq Scan")')
           OR jsonb_path_exists(plan, '$.**."Index Name" ? (@ == "vector_test_hnsw_idx")')
        THEN RAISE EXCEPTION 'Exact plan does not use an exhaustive scan for %', p; END IF;
        started := clock_timestamp();
        EXECUTE ranked INTO exact_ids, exact_d;
        exact_ms := round((extract(epoch FROM clock_timestamp() - started) * 1000)::numeric, 3);
        PERFORM set_config('enable_indexscan','on',true);
        PERFORM set_config('enable_seqscan','off',true);
        EXECUTE 'EXPLAIN (FORMAT JSON) ' || q INTO plan;
        IF NOT jsonb_path_exists(plan, '$.**."Index Name" ? (@ == "vector_test_hnsw_idx")')
        THEN RAISE EXCEPTION 'HNSW plan missing for %', p; END IF;
        started := clock_timestamp();
        EXECUTE ranked INTO found_ids, found_d;
        ann_ms := round((extract(epoch FROM clock_timestamp() - started) * 1000)::numeric, 3);
        SELECT count(*) INTO hits FROM unnest(found_ids) AS a(i) WHERE a.i = ANY(exact_ids);
        IF cardinality(exact_ids) IS DISTINCT FROM 10 OR cardinality(found_ids) IS DISTINCT FROM 10
           OR hits <> 10 OR exact_ids IS DISTINCT FROM found_ids OR exact_d IS DISTINCT FROM found_d
        THEN RAISE EXCEPTION 'HNSW mismatch for %, recall@10=%/10, exact IDs %, HNSW IDs %', p, hits, exact_ids, found_ids; END IF;
        RAISE NOTICE 'point=% recall@10=%/10 exact_ms=% hnsw_ms=%', p, hits, exact_ms, ann_ms;
        INSERT INTO retrieval VALUES (p, found_ids, found_d, hits);
    END LOOP;
END;
$compare$;

SELECT 'RESULT|extension|' || extversion FROM pg_extension WHERE extname = 'vector';
SELECT 'RESULT|rows|' || count(*) || '|' || count(embedding) || '|' ||
    md5(string_agg(id || ':' || coalesce(embedding::text, 'NULL'), E'\n' ORDER BY id)) FROM vector_test;
SELECT 'RESULT|type|' || format_type(atttypid, atttypmod)
FROM pg_attribute WHERE attrelid = 'vector_test'::regclass AND attname = 'embedding';
SELECT 'RESULT|index|' || indexdef FROM pg_indexes WHERE tablename = 'vector_test' ORDER BY indexname;
SELECT 'RESULT|constraint|' || pg_get_constraintdef(oid)
FROM pg_constraint WHERE conrelid = 'vector_test'::regclass ORDER BY conname;
SELECT 'RESULT|anchor|3,1,2|cosine=1|negative-inner-product=-11|nulls=1';
SELECT 'RESULT|recall|' || point || '|' || hits || '/10|' || ids::text || '|' || distances::text
FROM retrieval ORDER BY point;
