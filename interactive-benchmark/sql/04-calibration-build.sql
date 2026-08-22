-- Calibration build: 200M rows to measure bytes/row and rows/sec before full 4B build.

USE WAREHOUSE IA_BENCH_BUILD_WH;

CREATE OR REPLACE TABLE IA_BENCH.BENCH.FACT_CALIB AS
WITH gen AS (
    SELECT SEQ8() AS rn
    FROM TABLE(GENERATOR(ROWCOUNT => 200000000))
),
base AS (
    SELECT
        rn,
        GREATEST(1, LEAST(200000,
            FLOOR(200000 * POWER(UNIFORM(0::FLOAT, 1::FLOAT, RANDOM(11)), 2))
        ))::NUMBER(9,0) AS account_id
    FROM gen
)
SELECT
    account_id,
    DATEADD(day, UNIFORM(0, 59, RANDOM(12)), '2026-06-23'::DATE)                  AS event_date,
    DATEADD(second, UNIFORM(0, 86399, RANDOM(13)),
            DATEADD(day, UNIFORM(0, 59, RANDOM(12)), '2026-06-23'::DATE)::TIMESTAMP_NTZ) AS event_ts,
    CASE
        WHEN UNIFORM(1, 100, RANDOM(14)) <= 55 THEN 'dm'
        WHEN UNIFORM(1, 100, RANDOM(14)) <= 80 THEN 'link_click'
        WHEN UNIFORM(1, 100, RANDOM(14)) <= 93 THEN 'comment'
        WHEN UNIFORM(1, 100, RANDOM(14)) <= 98 THEN 'share'
        ELSE 'follow'
    END::VARCHAR(16)                                                              AS event_type,
    (account_id * 100000 + UNIFORM(0, 99999, RANDOM(15)))::NUMBER(18,0)           AS contact_id,
    (account_id * 1000 + UNIFORM(0, 999, RANDOM(16)))::NUMBER(18,0)               AS content_id,
    (account_id * 50 + UNIFORM(0, 49, RANDOM(17)))::NUMBER(18,0)                  AS campaign_id,
    CASE UNIFORM(1, 5, RANDOM(18))
        WHEN 1 THEN 'instagram' WHEN 2 THEN 'facebook' WHEN 3 THEN 'whatsapp'
        WHEN 4 THEN 'telegram' ELSE 'sms' END::VARCHAR(16)                        AS channel,
    CASE UNIFORM(1, 6, RANDOM(19))
        WHEN 1 THEN 'us-east' WHEN 2 THEN 'us-west' WHEN 3 THEN 'eu-central'
        WHEN 4 THEN 'apac-south' WHEN 5 THEN 'latam' ELSE 'mena' END::VARCHAR(24) AS region,
    CASE UNIFORM(1, 4, RANDOM(20))
        WHEN 1 THEN 'ios' WHEN 2 THEN 'android' WHEN 3 THEN 'web' ELSE 'desktop'
    END::VARCHAR(16)                                                              AS device,
    UUID_STRING()::VARCHAR(36)                                                    AS session_id,
    UUID_STRING()::VARCHAR(36)                                                    AS request_id,
    ('https://ref.example.com/p/' || UNIFORM(100000, 999999, RANDOM(21))::VARCHAR
        || '/' || UUID_STRING())::VARCHAR(96)                                     AS referrer,
    ('ua/' || UNIFORM(1, 9999, RANDOM(24))::VARCHAR || '/' || UUID_STRING())::VARCHAR(64) AS user_agent_hash,
    UNIFORM(1, 10, RANDOM(22))::NUMBER(9,0)                                       AS event_count,
    (UNIFORM(0, 50000, RANDOM(23)) / 100.0)::NUMBER(12,2)                         AS revenue
FROM base;

SELECT
    ROW_COUNT,
    BYTES,
    ROUND(BYTES / NULLIF(ROW_COUNT, 0), 2) AS bytes_per_row,
    ROUND(BYTES / POWER(1024, 3), 2)       AS gib
FROM IA_BENCH.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'BENCH' AND TABLE_NAME = 'FACT_CALIB';
