-- =============================================================================
-- WI-22 Interactive Analytics Benchmark — 02: warehouses
-- =============================================================================
-- Creates every warehouse the eight arms need.
--
-- COST SAFETY NOTES (these drove the choices below):
--   * Interactive warehouses have a ONE-HOUR MINIMUM BILLABLE PERIOD on every start or
--     resume, and a minimum AUTO_SUSPEND of 86400s (24h). Creating one costs nothing;
--     RESUMING one starts the clock.
--   * They are therefore created with AUTO_RESUME = FALSE so that a stray query cannot
--     silently resume one and burn an hour before we are ready to measure. Flipped to
--     TRUE in script 05, immediately before warming.
--   * FALLBACK_WAREHOUSE is mandatory here: the interactive 5s ceiling is enforced inside
--     the engine (confirmed: SHOW PARAMETERS reports 172800, so it is not settable), and
--     without a fallback, over-ceiling queries error instead of transparently retrying.
--     Docs also require the querying role to hold USAGE on BOTH warehouses.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- Build warehouse — generative CTAS for the 1B-row table. Large, short-lived.
-- Standard billing: 60s minimum then per-second, so a big size is cheap here.
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS IA_BENCH_BUILD_WH
    WAREHOUSE_SIZE = 'X-Large'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'WI-22: generative CTAS build warehouse for the 1B-row fact table';

-- -----------------------------------------------------------------------------
-- Fallback warehouse — receives queries that exceed the interactive 5s ceiling.
-- Sized at Medium: docs advise the fallback be the same size or larger than the
-- interactive warehouse it serves.
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS IA_BENCH_FALLBACK_WH
    WAREHOUSE_SIZE = 'Medium'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'WI-22: fallback for interactive warehouses (5s ceiling overflow)';

-- -----------------------------------------------------------------------------
-- Arm A / C / D — INTERACTIVE XS
-- -----------------------------------------------------------------------------
CREATE INTERACTIVE WAREHOUSE IF NOT EXISTS IA_BENCH_INTERACTIVE_XS
    WAREHOUSE_SIZE = 'X-Small'
    AUTO_SUSPEND = 86400
    AUTO_RESUME = FALSE
    COMMENT = 'WI-22 arms A/C/D: interactive XS';

-- -----------------------------------------------------------------------------
-- Arm E — INTERACTIVE M (size sweep vs arm A; may legitimately be a null result)
-- -----------------------------------------------------------------------------
CREATE INTERACTIVE WAREHOUSE IF NOT EXISTS IA_BENCH_INTERACTIVE_M
    WAREHOUSE_SIZE = 'Medium'
    AUTO_SUSPEND = 86400
    AUTO_RESUME = FALSE
    COMMENT = 'WI-22 arm E: interactive M';

-- -----------------------------------------------------------------------------
-- Arm B1 — size-matched standard Gen2 XS. Isolates warehouse TYPE.
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS IA_BENCH_STD_GEN2_XS
    WAREHOUSE_SIZE = 'X-Small'
    GENERATION = '2'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'WI-22 arm B1: standard Gen2 XS, size-matched to interactive XS';

-- -----------------------------------------------------------------------------
-- Arm B2 — multi-cluster XS. Realistic deployment; Manychat-comparable.
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS IA_BENCH_STD_MCW_XS
    WAREHOUSE_SIZE = 'X-Small'
    GENERATION = '2'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 4
    SCALING_POLICY = 'STANDARD'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'WI-22 arm B2: standard multi-cluster XS (up to 4 clusters)';

-- -----------------------------------------------------------------------------
-- Arm B3 — Adaptive. Current default recommendation for analytics; untested by
-- either referenced article.
-- -----------------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS IA_BENCH_ADAPTIVE_WH
    WAREHOUSE_TYPE = 'ADAPTIVE'
    COMMENT = 'WI-22 arm B3: adaptive warehouse baseline';

-- -----------------------------------------------------------------------------
-- Wire up fallback (requires the fallback warehouse to exist first)
-- -----------------------------------------------------------------------------
ALTER WAREHOUSE IA_BENCH_INTERACTIVE_XS SET FALLBACK_WAREHOUSE = IA_BENCH_FALLBACK_WH;
ALTER WAREHOUSE IA_BENCH_INTERACTIVE_M  SET FALLBACK_WAREHOUSE = IA_BENCH_FALLBACK_WH;

-- -----------------------------------------------------------------------------
-- COST BUG FIX (learned the hard way, 2026-08-20 22:17 PT)
--
-- The docs state an interactive warehouse "remains in a suspended state until you
-- resume it". OBSERVED BEHAVIOUR CONTRADICTS THIS: both interactive warehouses came up
-- STARTED immediately on CREATE, with resumed_on == created_on, despite AUTO_RESUME =
-- FALSE. Because an interactive warehouse bills a ONE-HOUR MINIMUM per start, that
-- silently burned ~1 hour on BOTH the XS and the Medium before any data existed.
--
-- INITIALLY_SUSPENDED is not documented for CREATE INTERACTIVE WAREHOUSE, so rather than
-- rely on it, suspend explicitly right after creation. Resume happens exactly once, in
-- script 05, when the data is built and we are ready to warm and run every arm in one
-- continuous window.
--
-- Do NOT remove these. Re-running this script without them restarts the billing clock.
-- -----------------------------------------------------------------------------
ALTER WAREHOUSE IA_BENCH_INTERACTIVE_XS SUSPEND;
ALTER WAREHOUSE IA_BENCH_INTERACTIVE_M  SUSPEND;

-- -----------------------------------------------------------------------------
-- Grants — role needs USAGE on every benchmark warehouse, plus the fallback
-- (docs: fallback support requires USAGE on both), plus MANAGE ATTACHED TABLES
-- to drive ALTER WAREHOUSE ... ADD TABLES.
-- -----------------------------------------------------------------------------
GRANT USAGE ON WAREHOUSE COMPUTE_WH             TO ROLE FLAKEBENCH_ROLE;
GRANT USAGE ON WAREHOUSE IA_BENCH_BUILD_WH      TO ROLE FLAKEBENCH_ROLE;
GRANT USAGE ON WAREHOUSE IA_BENCH_FALLBACK_WH   TO ROLE FLAKEBENCH_ROLE;
GRANT USAGE ON WAREHOUSE IA_BENCH_INTERACTIVE_XS TO ROLE FLAKEBENCH_ROLE;
GRANT USAGE ON WAREHOUSE IA_BENCH_INTERACTIVE_M  TO ROLE FLAKEBENCH_ROLE;
GRANT USAGE ON WAREHOUSE IA_BENCH_STD_GEN2_XS    TO ROLE FLAKEBENCH_ROLE;
GRANT USAGE ON WAREHOUSE IA_BENCH_STD_MCW_XS     TO ROLE FLAKEBENCH_ROLE;
GRANT USAGE ON WAREHOUSE IA_BENCH_ADAPTIVE_WH    TO ROLE FLAKEBENCH_ROLE;

GRANT MANAGE ATTACHED TABLES ON WAREHOUSE IA_BENCH_INTERACTIVE_XS TO ROLE FLAKEBENCH_ROLE;
GRANT MANAGE ATTACHED TABLES ON WAREHOUSE IA_BENCH_INTERACTIVE_M  TO ROLE FLAKEBENCH_ROLE;

-- -----------------------------------------------------------------------------
-- Verify: confirm type, size, fallback, and that interactive warehouses are
-- SUSPENDED with AUTO_RESUME = false (no billing started).
-- -----------------------------------------------------------------------------
SHOW WAREHOUSES LIKE 'IA_BENCH%';
