-- =============================================================================
-- WI-22 Interactive Analytics Benchmark — 01: role, database, warehouses
-- =============================================================================
-- Adapted from FlakeBench sql/setup_role.sql for account DEMO_ATAHIR.
--
-- Differences from the shipped script, and why:
--   * Adds MANAGE ATTACHED TABLES on the interactive warehouses. Required for
--     ALTER WAREHOUSE ... ADD TABLES. FlakeBench never issues that command
--     (verified: absent from the repo), so attachment is ours to perform, but the
--     role still needs the privilege for any attachment we drive through it.
--   * Adds USAGE on the fallback warehouse. Docs: to query with fallback support the
--     querying role needs USAGE on BOTH the interactive warehouse and its fallback.
--     Without this, arms fail instead of falling back.
--   * Adds the benchmark database plus SELECT on its tables AND semantic views —
--     the agent corpus replays SELECT ... FROM SEMANTIC_VIEW(...), so semantic-view
--     SELECT is not optional.
--   * Grants the role to USER ATAHIR for standalone (non-SPCS) use.
--
-- Naming convention: everything is prefixed IA_BENCH_ so teardown is unambiguous.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- -----------------------------------------------------------------------------
-- Control plane (FlakeBench's own results storage)
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS FLAKEBENCH;
CREATE SCHEMA IF NOT EXISTS FLAKEBENCH.TEST_RESULTS;

CREATE ROLE IF NOT EXISTS FLAKEBENCH_ROLE;

GRANT OWNERSHIP ON DATABASE FLAKEBENCH TO ROLE FLAKEBENCH_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON SCHEMA FLAKEBENCH.TEST_RESULTS TO ROLE FLAKEBENCH_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL TABLES IN SCHEMA FLAKEBENCH.TEST_RESULTS TO ROLE FLAKEBENCH_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON ALL VIEWS  IN SCHEMA FLAKEBENCH.TEST_RESULTS TO ROLE FLAKEBENCH_ROLE COPY CURRENT GRANTS;
GRANT OWNERSHIP ON FUTURE TABLES IN SCHEMA FLAKEBENCH.TEST_RESULTS TO ROLE FLAKEBENCH_ROLE;
GRANT OWNERSHIP ON FUTURE VIEWS  IN SCHEMA FLAKEBENCH.TEST_RESULTS TO ROLE FLAKEBENCH_ROLE;

-- -----------------------------------------------------------------------------
-- Benchmark data plane
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS IA_BENCH;
CREATE SCHEMA IF NOT EXISTS IA_BENCH.BENCH;

GRANT USAGE ON DATABASE IA_BENCH TO ROLE FLAKEBENCH_ROLE;
GRANT USAGE ON SCHEMA IA_BENCH.BENCH TO ROLE FLAKEBENCH_ROLE;
GRANT SELECT ON ALL TABLES    IN SCHEMA IA_BENCH.BENCH TO ROLE FLAKEBENCH_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA IA_BENCH.BENCH TO ROLE FLAKEBENCH_ROLE;
GRANT SELECT ON ALL VIEWS     IN SCHEMA IA_BENCH.BENCH TO ROLE FLAKEBENCH_ROLE;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA IA_BENCH.BENCH TO ROLE FLAKEBENCH_ROLE;

-- Semantic views are a distinct object type; the agent corpus queries them directly.
GRANT SELECT ON ALL SEMANTIC VIEWS    IN SCHEMA IA_BENCH.BENCH TO ROLE FLAKEBENCH_ROLE;
GRANT SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA IA_BENCH.BENCH TO ROLE FLAKEBENCH_ROLE;

-- -----------------------------------------------------------------------------
-- Role hierarchy
-- -----------------------------------------------------------------------------
GRANT ROLE FLAKEBENCH_ROLE TO ROLE SYSADMIN;
GRANT ROLE FLAKEBENCH_ROLE TO USER ATAHIR;

-- -----------------------------------------------------------------------------
-- Verify
-- -----------------------------------------------------------------------------
SHOW GRANTS TO ROLE FLAKEBENCH_ROLE;
