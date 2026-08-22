-- =============================================================================
-- WI-22 Interactive Analytics Benchmark -- 09: Cortex Agent (agentic analyst)
-- =============================================================================
-- Per the Apr 2026 agentic-analyst release note, an agent with a semantic-view tool now
-- generates SQL DIRECTLY rather than delegating to the Cortex Analyst service. The tool
-- definition is unchanged (`cortex_analyst_text_to_sql`), but the response contains
-- `system_execute_sql` blocks carrying `sql`, `query_id`, and a final `sql`.
--
-- THE CRITICAL FIELD FOR ARM F:
--   tool_resources.<Tool>.execution_environment.warehouse
-- This is the warehouse the agent's generated SQL actually runs on. Arm F flips it between
-- IA_BENCH_INTERACTIVE_XS and IA_BENCH_STD_GEN2_XS to compare the live agentic path.
--
-- Set to COMPUTE_WH here because corpus harvesting does not need the interactive warehouse,
-- and the interactive warehouse is deliberately kept SUSPENDED until every arm can run in a
-- single warm window (each resume costs a 1-hour minimum).
--
-- Orchestration instructions are deliberately plain: the goal is to observe what the agent
-- naturally emits, not to coach it into writing efficient SQL. Over-instructing here would
-- bias the very thing the benchmark measures.
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE OR REPLACE AGENT IA_BENCH.BENCH.ENGAGEMENT_AGENT
WITH PROFILE = '{"display_name": "Engagement Analyst (benchmark)"}'
    COMMENT = 'WI-22: agentic analyst over SV_ENGAGEMENT, used to harvest a realistic analytical query corpus'
FROM SPECIFICATION $$
{
  "models": { "orchestration": "auto" },
  "orchestration": { "budget": { "seconds": 120, "tokens": 32000 } },
  "instructions": {
    "response": "You are an analytics assistant for a creator-engagement platform. Answer with concrete numbers. Always scope answers to the account and date range the user asks about.",
    "orchestration": "Use EngagementAnalyst for all quantitative questions about engagement events: counts, distinct subscribers, totals, ratios, rankings, and period-over-period comparisons.",
    "sample_questions": [
      { "question": "How many unique subscribers did account 50000 touch in the last 30 days?" },
      { "question": "What is the click-to-DM ratio for account 12345 by channel this month?" },
      { "question": "Show the top 50 content items for account 777 by unique subscribers." },
      { "question": "How did unique subscribers for account 99 change versus the prior 30 days?" }
    ]
  },
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "EngagementAnalyst",
        "description": "Converts natural language into SQL over the creator engagement semantic view. Use for counts, distinct subscriber counts, event totals, revenue, click-to-DM ratios, per-content rankings, and period-over-period deltas, filtered by account, date range, channel, region, device, or event type."
      }
    }
  ],
  "tool_resources": {
    "EngagementAnalyst": {
      "semantic_view": "IA_BENCH.BENCH.SV_ENGAGEMENT",
      "execution_environment": {
        "type": "warehouse",
        "warehouse": "COMPUTE_WH"
      }
    }
  }
}
$$;

DESCRIBE AGENT IA_BENCH.BENCH.ENGAGEMENT_AGENT;
