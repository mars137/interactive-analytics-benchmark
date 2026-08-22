-- Control corpora, server-side truth. Correlated by QUERY_TAG (exact) rather than by time
-- window, because run_controls.py sets a tag per corpus/query: 'wi22_ctl_<cond>|<corpus>|<class>'.
-- This is strictly better than the window correlation the FlakeBench arms required, and it also
-- strips out the ~200-300ms of driver/network overhead visible in the client-side numbers.

WITH q AS (
    SELECT
        SPLIT_PART(QUERY_TAG, '|', 1) AS cond_tag,
        SPLIT_PART(QUERY_TAG, '|', 2) AS corpus,
        SPLIT_PART(QUERY_TAG, '|', 3) AS q_class,
        h.*
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY h
    WHERE QUERY_TAG LIKE 'wi22_ctl_%'
      AND QUERY_TAG NOT LIKE '%_smoke%'
      AND START_TIME >= '2026-08-21'::date
      AND QUERY_TYPE = 'SELECT'
)
SELECT
    corpus,
    q_class,
    CASE cond_tag WHEN 'wi22_ctl_int' THEN 'interactive' ELSE 'standard' END AS cond,
    COUNT(*)                                                     AS n,
    SUM(IFF(EXECUTION_STATUS != 'SUCCESS',1,0))                  AS failed,
    SUM(IFF(WAREHOUSE_TYPE != 'INTERACTIVE',1,0))                AS non_int_wh,
    SUM(IFF(COALESCE(FAULT_HANDLING_TIME,0) > 0,1,0))            AS fault_handled,
    ROUND(MEDIAN(TOTAL_ELAPSED_TIME))                            AS p50_ms,
    ROUND(APPROX_PERCENTILE(TOTAL_ELAPSED_TIME,0.90))            AS p90_ms,
    ROUND(APPROX_PERCENTILE(TOTAL_ELAPSED_TIME,0.99))            AS p99_ms,
    MAX(TOTAL_ELAPSED_TIME)                                      AS max_ms,
    ROUND(MEDIAN(COMPILATION_TIME))                              AS p50_compile_ms,
    ROUND(MEDIAN(EXECUTION_TIME))                                AS p50_exec_ms,
    ROUND(100 * AVG(COMPILATION_TIME/NULLIF(TOTAL_ELAPSED_TIME,0)),1) AS pct_compile,
    ROUND(100 * SUM(BYTES_SCANNED*PERCENTAGE_SCANNED_FROM_CACHE)
              / NULLIF(SUM(BYTES_SCANNED),0),1)                  AS cache_pct_wtd
FROM q
GROUP BY corpus, q_class, cond
ORDER BY corpus, q_class, cond DESC;
