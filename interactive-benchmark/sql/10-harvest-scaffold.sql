-- =============================================================================
-- WI-22 Interactive Analytics Benchmark -- 10: harvest scaffolding
-- =============================================================================
-- Harvest MUST be server-side: DATA_AGENT_RUN output truncates at 4 KB in client display,
-- so the full response is stored as VARIANT and flattened in SQL.
--
-- Question design: 4 query classes x 6 accounts spanning the skew tiers, with varied
-- windows. The classes deliberately mirror the Manychat set so the agent corpus and the
-- hand-written control corpus stay comparable:
--   Q1 unique subscribers        -- non-additive, single scan
--   Q2 click-to-DM ratio         -- additive components, single scan
--   Q3 top content by subscribers-- GROUP BY + per-group COUNT DISTINCT
--   Q4 period-over-period delta  -- double scan
--
-- Account tiers come from the MEASURED distribution (10M-row pilot, power law alpha=2):
--   whale  = account_id 1-3       (top account had ~6.1M rows in a 30d window at 4B scale)
--   heavy  = 100-500
--   mid    = 50000-120000         (account 50000 measured ~9.8k rows in a 30d window)
--   light  = 190000+
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE OR REPLACE TABLE IA_BENCH.BENCH.AGENT_QUESTIONS (
    q_id        NUMBER,
    q_class     VARCHAR(4),      -- Q1..Q4
    tier        VARCHAR(8),      -- whale/heavy/mid/light
    account_id  NUMBER,
    window_days NUMBER,
    question    VARCHAR
);

INSERT INTO IA_BENCH.BENCH.AGENT_QUESTIONS
    (q_id, q_class, tier, account_id, window_days, question)
VALUES
-- Q1: unique subscribers (non-additive, single scan)
(1,  'Q1', 'whale', 1,      30, 'How many unique subscribers did account 1 touch in the 30 days ending 2026-08-21?'),
(2,  'Q1', 'heavy', 250,    30, 'How many unique subscribers did account 250 touch in the 30 days ending 2026-08-21?'),
(3,  'Q1', 'mid',   50000,  30, 'How many unique subscribers did account 50000 touch in the 30 days ending 2026-08-21?'),
(4,  'Q1', 'light', 190000, 30, 'How many unique subscribers did account 190000 touch in the 30 days ending 2026-08-21?'),
(5,  'Q1', 'whale', 2,       7, 'Count the distinct subscribers for account 2 over the 7 days ending 2026-08-21.'),
(6,  'Q1', 'mid',   75000,  15, 'Count the distinct subscribers for account 75000 over the 15 days ending 2026-08-21.'),

-- Q2: click-to-DM ratio (additive components)
(7,  'Q2', 'whale', 1,      30, 'What is the click-to-DM ratio for account 1 in the 30 days ending 2026-08-21?'),
(8,  'Q2', 'heavy', 500,    30, 'What is the click-to-DM ratio for account 500 in the 30 days ending 2026-08-21?'),
(9,  'Q2', 'mid',   50000,  30, 'What is the click-to-DM ratio for account 50000 by channel in the 30 days ending 2026-08-21?'),
(10, 'Q2', 'light', 199000, 30, 'What is the click-to-DM ratio for account 199000 in the 30 days ending 2026-08-21?'),
(11, 'Q2', 'heavy', 100,    15, 'Show the click-to-DM ratio for account 100 by region over the 15 days ending 2026-08-21.'),
(12, 'Q2', 'mid',   120000,  7, 'Show total events and the click-to-DM ratio for account 120000 over the 7 days ending 2026-08-21.'),

-- Q3: grouped + per-group COUNT DISTINCT
(13, 'Q3', 'whale', 1,      30, 'Show the top 50 content items for account 1 by unique subscribers in the 30 days ending 2026-08-21.'),
(14, 'Q3', 'heavy', 250,    30, 'Show the top 50 content items for account 250 by unique subscribers in the 30 days ending 2026-08-21.'),
(15, 'Q3', 'mid',   50000,  30, 'Show the top 50 content items for account 50000 by unique subscribers in the 30 days ending 2026-08-21.'),
(16, 'Q3', 'light', 190000, 30, 'Show the top content items for account 190000 by unique subscribers in the 30 days ending 2026-08-21.'),
(17, 'Q3', 'whale', 3,      15, 'Which content performed best for account 3 by unique subscribers and total events over the 15 days ending 2026-08-21?'),
(18, 'Q3', 'mid',   75000,  30, 'Break down unique subscribers by channel and device for account 75000 in the 30 days ending 2026-08-21.'),

-- Q4: period-over-period delta (double scan)
(19, 'Q4', 'whale', 1,      30, 'How did unique subscribers for account 1 in the 30 days ending 2026-08-21 compare with the previous 30 days?'),
(20, 'Q4', 'heavy', 250,    30, 'How did unique subscribers for account 250 in the 30 days ending 2026-08-21 compare with the previous 30 days?'),
(21, 'Q4', 'mid',   50000,  30, 'How did unique subscribers for account 50000 in the 30 days ending 2026-08-21 compare with the previous 30 days?'),
(22, 'Q4', 'light', 190000, 30, 'Compare unique subscribers for account 190000 in the last 30 days ending 2026-08-21 against the prior 30 days.'),
(23, 'Q4', 'heavy', 500,    15, 'Compare total events for account 500 in the 15 days ending 2026-08-21 against the prior 15 days.'),
(24, 'Q4', 'mid',   120000, 15, 'Did unique subscribers for account 120000 grow or shrink versus the prior 15 days, as of 2026-08-21?');

-- Raw agent responses. resp holds the FULL JSON; never rely on client-side output.
CREATE OR REPLACE TABLE IA_BENCH.BENCH.AGENT_HARVEST (
    q_id         NUMBER,
    question     VARCHAR,
    resp         VARIANT,
    harvested_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    error        VARCHAR
);

SELECT COUNT(*) AS questions_loaded FROM IA_BENCH.BENCH.AGENT_QUESTIONS;
