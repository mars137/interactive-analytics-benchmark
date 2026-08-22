-- Fallback proof + arm D shape probe, all in ONE session so LAST_QUERY_ID() works.
--
-- Why this exists: SHOW WAREHOUSES on this account has no FALLBACK_WAREHOUSE column, so
-- the ALTER ... SET FALLBACK_WAREHOUSE could only be confirmed functionally. Per docs, a
-- query exceeding the interactive 5s ceiling is transparently re-run on the fallback
-- warehouse and the lost time appears as FAULT_HANDLING_TIME.
--
-- The filter here is deliberately selective, but FACT_NONCLUSTERED has clustering depth
-- 24448 (every partition overlaps every other), so it CANNOT prune -- a single-account
-- filter still scans all partitions. That is exactly the arm D pathology.

USE WAREHOUSE IA_BENCH_INTERACTIVE_XS;

SELECT CURRENT_WAREHOUSE() AS wh_before;

SELECT COUNT(DISTINCT contact_id) AS distinct_contacts, COUNT(*) AS rows_matched
FROM IA_BENCH.BENCH.FACT_NONCLUSTERED
WHERE account_id = 1
  AND event_date >= '2026-07-24'::DATE;

SET probe_id = (SELECT LAST_QUERY_ID());
SELECT $probe_id AS probe_query_id;

-- Warm-state + pruning evidence for that exact query
SELECT
    OPERATOR_TYPE,
    OPERATOR_STATISTICS:io:percentage_scanned_from_cache::FLOAT AS pct_from_cache,
    OPERATOR_STATISTICS:pruning:partitions_scanned::BIGINT      AS partitions_scanned,
    OPERATOR_STATISTICS:pruning:partitions_total::BIGINT        AS partitions_total,
    OPERATOR_STATISTICS:io:bytes_scanned::BIGINT                AS bytes_scanned
FROM TABLE(GET_QUERY_OPERATOR_STATS($probe_id))
WHERE OPERATOR_TYPE = 'TableScan';
