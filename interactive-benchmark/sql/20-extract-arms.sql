-- Per-arm extraction + FALLBACK SCREEN.
--
-- Correlation is by (warehouse, time window) because FlakeBench's QUERY_EXECUTIONS table is
-- empty on this account, so there is no test_id to join on. Windows come from
-- /tmp/wi22_arm_windows.tsv, which the orchestrator writes.
--
-- The fallback screen is NOT optional. A query that breaches the interactive 5s ceiling is
-- re-run on the FALLBACK_WAREHOUSE and returns SUCCESS -- it looks like a perfectly normal
-- interactive result. The only tells are WAREHOUSE_TYPE != 'INTERACTIVE' and
-- FAULT_HANDLING_TIME > 0. Any arm with fallback in it is not measuring what its name says.

WITH windows AS (
    SELECT * FROM VALUES
      ('D',  'IA_BENCH_INTERACTIVE_XS', '2026-08-21 22:11:48', '2026-08-21 22:18:39'),
      ('A',  'IA_BENCH_INTERACTIVE_XS', '2026-08-21 22:24:38', '2026-08-21 22:30:24'),
      ('E',  'IA_BENCH_INTERACTIVE_M',  '2026-08-21 22:40:32', '2026-08-21 22:46:08'),
      ('B1', 'IA_BENCH_STD_GEN2_XS',    '2026-08-21 22:46:13', '2026-08-21 22:51:35'),
      ('B2', 'IA_BENCH_STD_MCW_XS',     '2026-08-21 22:51:35', '2026-08-21 22:57:16'),
      ('B3', 'IA_BENCH_ADAPTIVE_WH',    '2026-08-21 22:57:16', '2026-08-21 23:03:02'),
      -- arm C re-run after the INTERACTIVE_TABLE grant fix; the original 22:35 attempt failed
      -- every query in 33s and is deliberately excluded.
      ('C',  'IA_BENCH_INTERACTIVE_XS', '2026-08-21 23:11:19', '2026-08-21 23:17:05')
      AS t(arm, wh, start_utc, end_utc)
),
q AS (
    SELECT w.arm, w.wh, h.*
    FROM windows w
    JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY h
      ON h.WAREHOUSE_NAME = w.wh
     AND h.START_TIME >= TO_TIMESTAMP_TZ(w.start_utc || ' +0000')
     AND h.START_TIME <  TO_TIMESTAMP_TZ(w.end_utc   || ' +0000')
    WHERE h.USER_NAME = 'IA_BENCH_SVC'
      AND h.QUERY_TYPE = 'SELECT'
)
SELECT
    arm,
    COUNT(*)                                                    AS queries,
    SUM(IFF(EXECUTION_STATUS = 'SUCCESS', 1, 0))                AS ok,
    SUM(IFF(EXECUTION_STATUS != 'SUCCESS', 1, 0))               AS failed,
    -- FALLBACK SCREEN
    SUM(IFF(WAREHOUSE_TYPE != 'INTERACTIVE', 1, 0))             AS non_interactive_wh,
    SUM(IFF(COALESCE(FAULT_HANDLING_TIME,0) > 0, 1, 0))         AS fault_handled,
    -- latency
    ROUND(MEDIAN(TOTAL_ELAPSED_TIME))                           AS p50_ms,
    ROUND(APPROX_PERCENTILE(TOTAL_ELAPSED_TIME, 0.90))          AS p90_ms,
    ROUND(APPROX_PERCENTILE(TOTAL_ELAPSED_TIME, 0.99))          AS p99_ms,
    MAX(TOTAL_ELAPSED_TIME)                                     AS max_ms,
    -- where the time goes
    ROUND(MEDIAN(COMPILATION_TIME))                             AS p50_compile_ms,
    ROUND(MEDIAN(EXECUTION_TIME))                               AS p50_exec_ms,
    ROUND(100 * AVG(COMPILATION_TIME / NULLIF(TOTAL_ELAPSED_TIME,0)), 1) AS pct_compile,
    -- pruning + cache (achieved warm state, reported retrospectively)
    ROUND(100 * AVG(PARTITIONS_SCANNED / NULLIF(PARTITIONS_TOTAL,0)), 4) AS pct_partitions,
    -- Cache: bytes-weighted, per the docs' own recommended aggregate. An unweighted AVG(pct)
    -- misleads whenever scan sizes vary a lot within an arm (as in the unclustered arm).
    ROUND(100 * SUM(BYTES_SCANNED * PERCENTAGE_SCANNED_FROM_CACHE)
              / NULLIF(SUM(BYTES_SCANNED),0), 2)                AS cache_pct_wtd,
    ROUND(100 * AVG(PERCENTAGE_SCANNED_FROM_CACHE), 2)          AS cache_pct_unwtd,
    SUM(IFF(COALESCE(QUERY_RETRY_TIME,0) > 0, 1, 0))            AS retried
FROM q
GROUP BY arm
ORDER BY arm;
