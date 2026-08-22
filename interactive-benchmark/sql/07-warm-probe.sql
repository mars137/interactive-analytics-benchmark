-- Warm-state probe. Gate is "has pct_from_cache stopped rising" (not 100%, since table > cache).

USE WAREHOUSE IA_BENCH_INTERACTIVE_XS;

-- Must disable result cache or repeated probes return no TableScan operator.
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Vary account per run to sample different partitions.
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
