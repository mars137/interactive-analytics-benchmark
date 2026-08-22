-- Warm-state probe. Run repeatedly until pct_from_cache PLATEAUS.
--
-- NOTE the revised gate: with a ~400 GB table against a 350 GB interactive XS cache, the
-- cache can never hold everything, so pct_from_cache will NEVER reach 100. Steady state is
-- roughly 350/400 ~= 87%. The gate is therefore "has it stopped rising", not "is it ~100".
-- Record the plateau value -- it is the mechanism behind any XS vs M difference in arm E.
--
-- Uses a mid-range account and a 30-day window so the probe is representative of the real
-- workload rather than touching an unusually hot or cold slice.

USE WAREHOUSE IA_BENCH_INTERACTIVE_XS;

-- CRITICAL: without this, repeating the probe hits the RESULT cache and returns no
-- TableScan operator at all (observed: third probe returned all NULLs). We want the
-- table DATA cache, never the result cache.
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Vary the account per run so we sample different partitions rather than re-reading one
-- warm slice, which would overstate cache coverage.
SELECT COUNT(*) AS rows_matched, SUM(event_count) AS total_events
FROM IA_BENCH.BENCH.FACT_NONCLUSTERED
WHERE account_id = 50000
  AND event_date >= '2026-07-24'::DATE;

SET probe_id = (SELECT LAST_QUERY_ID());

SELECT
    CURRENT_TIMESTAMP()                                          AS probed_at,
    ROUND(AVG(OPERATOR_STATISTICS:io:percentage_scanned_from_cache::FLOAT), 3) AS avg_pct_from_cache,
    SUM(OPERATOR_STATISTICS:io:bytes_scanned::BIGINT)             AS bytes_scanned,
    MAX(OPERATOR_STATISTICS:pruning:partitions_scanned::BIGINT)   AS partitions_scanned,
    MAX(OPERATOR_STATISTICS:pruning:partitions_total::BIGINT)     AS partitions_total
FROM TABLE(GET_QUERY_OPERATOR_STATS($probe_id))
WHERE OPERATOR_TYPE = 'TableScan';
