-- =============================================================================
-- WI-22 Interactive Analytics Benchmark -- 12: hand-written CONTROL corpus
-- =============================================================================
-- Two control sets, both hand-written, to answer questions the agent corpus alone cannot:
--
--   CONTROL_SV   -- the four Manychat classes expressed in SEMANTIC_VIEW() syntax.
--                   Purpose: quantify the semantic-view expansion cost at query time.
--                   Motivation: a SEMANTIC_VIEW() probe earlier spent 2427 ms of 2582 ms
--                   (94%) in COMPILATION on a ~30-account view. The agent NEVER uses this
--                   syntax -- it emits pre-expanded CTE SQL -- so this control measures what
--                   the agent's own expansion SAVES.
--
--   CONTROL_HUMAN -- the same four classes as base-table SQL written the way the Manychat
--                   article writes them. Critically, Q4 uses the TWO-CTE / TWO-SCAN form.
--                   Purpose: compare against the agent's single-scan conditional aggregation
--                   for the same question. This is the agent-vs-human SQL comparison.
--
-- Both use `?` for account_id, matching the agent corpus, so all corpora share one bind
-- convention and one account pool.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE OR REPLACE TABLE IA_BENCH.BENCH.CONTROL_CORPUS (
    ctl_id      NUMBER,
    corpus      VARCHAR(16),   -- CONTROL_SV | CONTROL_HUMAN
    q_class     VARCHAR(4),
    note        VARCHAR,
    param_count NUMBER,
    sql_text    VARCHAR
);

-- -----------------------------------------------------------------------------
-- CONTROL_SV -- SEMANTIC_VIEW() syntax (the path the agent does NOT take)
-- -----------------------------------------------------------------------------
INSERT INTO IA_BENCH.BENCH.CONTROL_CORPUS (ctl_id, corpus, q_class, note, param_count, sql_text)
SELECT 1, 'CONTROL_SV', 'Q1', 'unique subscribers, single scan', 1,
$$SELECT * FROM SEMANTIC_VIEW(
    IA_BENCH.BENCH.SV_ENGAGEMENT
    METRICS events.unique_contacts
    WHERE events.account_id = ? AND events.event_date >= DATEADD(DAY, -29, CURRENT_DATE)
)$$
UNION ALL SELECT 2, 'CONTROL_SV', 'Q2', 'click-to-dm ratio, additive', 1,
$$SELECT * FROM SEMANTIC_VIEW(
    IA_BENCH.BENCH.SV_ENGAGEMENT
    METRICS events.click_to_dm_ratio, events.total_events
    WHERE events.account_id = ? AND events.event_date >= DATEADD(DAY, -29, CURRENT_DATE)
)$$
UNION ALL SELECT 3, 'CONTROL_SV', 'Q3', 'top content by unique subscribers', 1,
$$SELECT * FROM SEMANTIC_VIEW(
    IA_BENCH.BENCH.SV_ENGAGEMENT
    DIMENSIONS events.content_id
    METRICS events.unique_contacts, events.total_events
    WHERE events.account_id = ? AND events.event_date >= DATEADD(DAY, -29, CURRENT_DATE)
) ORDER BY unique_contacts DESC NULLS LAST LIMIT 50$$
UNION ALL SELECT 4, 'CONTROL_SV', 'Q3b', 'grouped by channel and device', 1,
$$SELECT * FROM SEMANTIC_VIEW(
    IA_BENCH.BENCH.SV_ENGAGEMENT
    DIMENSIONS events.channel, events.device
    METRICS events.unique_contacts, events.total_events
    WHERE events.account_id = ? AND events.event_date >= DATEADD(DAY, -29, CURRENT_DATE)
)$$;

-- -----------------------------------------------------------------------------
-- CONTROL_HUMAN -- base-table SQL, Manychat style. Q4 is deliberately TWO scans.
-- -----------------------------------------------------------------------------
INSERT INTO IA_BENCH.BENCH.CONTROL_CORPUS (ctl_id, corpus, q_class, note, param_count, sql_text)
SELECT 11, 'CONTROL_HUMAN', 'Q1', 'unique subscribers, single scan', 1,
$$SELECT COUNT(DISTINCT contact_id) AS unique_subscribers
FROM IA_BENCH.BENCH.FACT_CLUSTERED
WHERE account_id = ? AND event_date >= DATEADD(DAY, -29, CURRENT_DATE)$$
UNION ALL SELECT 12, 'CONTROL_HUMAN', 'Q2', 'click-to-dm ratio, additive', 1,
$$SELECT SUM(CASE WHEN event_type = 'link_click' THEN event_count END)
       / NULLIF(SUM(CASE WHEN event_type = 'dm' THEN event_count END), 0) AS click_to_dm_ratio
FROM IA_BENCH.BENCH.FACT_CLUSTERED
WHERE account_id = ? AND event_date >= DATEADD(DAY, -29, CURRENT_DATE)$$
UNION ALL SELECT 13, 'CONTROL_HUMAN', 'Q3', 'top 50 content, per-group distinct', 1,
$$SELECT content_id,
       COUNT(DISTINCT contact_id) AS unique_subscribers,
       SUM(event_count)           AS total_events
FROM IA_BENCH.BENCH.FACT_CLUSTERED
WHERE account_id = ? AND event_date >= DATEADD(DAY, -29, CURRENT_DATE)
GROUP BY content_id
ORDER BY unique_subscribers DESC
LIMIT 50$$
UNION ALL SELECT 14, 'CONTROL_HUMAN', 'Q4', 'delta -- TWO CTEs, TWO scans (Manychat form)', 1,
$$WITH current_window AS (
    SELECT COUNT(DISTINCT contact_id) AS c
    FROM IA_BENCH.BENCH.FACT_CLUSTERED
    WHERE account_id = ? AND event_date BETWEEN DATEADD(DAY, -29, CURRENT_DATE) AND CURRENT_DATE
),
prior_window AS (
    SELECT COUNT(DISTINCT contact_id) AS c
    FROM IA_BENCH.BENCH.FACT_CLUSTERED
    WHERE account_id = ? AND event_date BETWEEN DATEADD(DAY, -59, CURRENT_DATE) AND DATEADD(DAY, -30, CURRENT_DATE)
)
SELECT current_window.c - prior_window.c AS delta
FROM current_window, prior_window$$;

-- ctl_id 14 has TWO placeholders (one per CTE) -- fix its declared param_count
UPDATE IA_BENCH.BENCH.CONTROL_CORPUS SET param_count = 2 WHERE ctl_id = 14;

SELECT ctl_id, corpus, q_class, param_count,
       REGEXP_COUNT(sql_text, '\\?') AS actual_placeholders,
       IFF(param_count = REGEXP_COUNT(sql_text, '\\?'), 'ok', 'MISMATCH') AS check_result
FROM IA_BENCH.BENCH.CONTROL_CORPUS
ORDER BY ctl_id;
