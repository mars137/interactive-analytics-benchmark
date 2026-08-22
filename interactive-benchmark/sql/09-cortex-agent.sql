-- WI-22: Cortex Agent for harvesting an analyst query corpus.
-- execution_environment.warehouse set to COMPUTE_WH (interactive WHs stay suspended until arms run).

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
