-- =============================================================================
-- WI-22 Interactive Analytics Benchmark -- 05b: clustered + interactive variants
-- =============================================================================
-- Builds the two retained variants from FACT_NONCLUSTERED:
--   FACT_CLUSTERED   -- standard table, CLUSTER BY (account_id, event_date)  -> arms A/B/E
--   FACT_INTERACTIVE -- interactive table, same clustering                   -> arm C
--
-- FACT_NONCLUSTERED itself is the arm D subject (pruning cliff), so it is not copied.
--
-- THREE COST DECISIONS ENCODED HERE:
--
-- 1. ORDER BY inside the CTAS. CLUSTER BY alone only registers a clustering key; the data
--    converges later via automatic clustering, which costs serverless credits AND would
--    leave the table poorly clustered while the benchmark runs. Sorting up front gets
--    well-clustered data immediately.
--
-- 2. Warehouse temporarily resized to 2X-Large for the sorts. Sorting 4B rows / 400 GiB
--    spills heavily on X-Large. A larger warehouse has more memory and local SSD, so it
--    spills less -- often finishing more than proportionally faster, making the sort
--    cheaper in credits as well as faster in wall clock. Resized back at the end.
--
-- 3. SUSPEND RECLUSTER after build. The data is static, so automatic clustering would
--    accrue serverless credits for the whole benchmark and change table layout underneath
--    the arms. Easy to forget; would quietly corrupt both the cost story and reproducibility.
--
-- Interactive tables are created with a STANDARD warehouse (per docs); the interactive
-- warehouse is only used to query them, and stays SUSPENDED throughout this script.
-- =============================================================================

ALTER WAREHOUSE IA_BENCH_BUILD_WH SET WAREHOUSE_SIZE = '2X-Large';
USE WAREHOUSE IA_BENCH_BUILD_WH;

-- -----------------------------------------------------------------------------
-- Clustered standard table -- arms A, B1, B2, B3, E
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE IA_BENCH.BENCH.FACT_CLUSTERED
    CLUSTER BY (account_id, event_date)
AS
SELECT * FROM IA_BENCH.BENCH.FACT_NONCLUSTERED
ORDER BY account_id, event_date;

ALTER TABLE IA_BENCH.BENCH.FACT_CLUSTERED SUSPEND RECLUSTER;

-- -----------------------------------------------------------------------------
-- Interactive table -- arm C. CLUSTER BY is mandatory for CREATE INTERACTIVE TABLE.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE INTERACTIVE TABLE IA_BENCH.BENCH.FACT_INTERACTIVE
    CLUSTER BY (account_id, event_date)
AS
SELECT * FROM IA_BENCH.BENCH.FACT_NONCLUSTERED
ORDER BY account_id, event_date;

-- -----------------------------------------------------------------------------
-- Back to X-Large so the build warehouse is not left oversized.
-- -----------------------------------------------------------------------------
ALTER WAREHOUSE IA_BENCH_BUILD_WH SET WAREHOUSE_SIZE = 'X-Large';

-- -----------------------------------------------------------------------------
-- Verify: sizes, row counts, and that clustering actually took effect
-- -----------------------------------------------------------------------------
SELECT
    TABLE_NAME,
    ROW_COUNT,
    ROUND(BYTES / POWER(1024, 3), 2)       AS gib,
    ROUND(BYTES / NULLIF(ROW_COUNT, 0), 2) AS bytes_per_row,
    CLUSTERING_KEY
FROM IA_BENCH.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'BENCH'
ORDER BY TABLE_NAME;

SELECT 'FACT_CLUSTERED' AS tbl,
       SYSTEM$CLUSTERING_INFORMATION('IA_BENCH.BENCH.FACT_CLUSTERED', '(account_id, event_date)') AS info;

SELECT 'FACT_NONCLUSTERED' AS tbl,
       SYSTEM$CLUSTERING_INFORMATION('IA_BENCH.BENCH.FACT_NONCLUSTERED', '(account_id, event_date)') AS info;

SHOW INTERACTIVE TABLES IN SCHEMA IA_BENCH.BENCH;
