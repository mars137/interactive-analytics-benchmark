-- WI-22: semantic view for the agentic path (over FACT_CLUSTERED).

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;

CREATE OR REPLACE SEMANTIC VIEW IA_BENCH.BENCH.SV_ENGAGEMENT
    tables (
        EVENTS as IA_BENCH.BENCH.FACT_CLUSTERED
            with synonyms = ('events','engagement events','activity','interactions')
            comment = 'One row per engagement event for a creator account'
    )
    facts (
        EVENTS.EVENT_COUNT as event_count,
        EVENTS.REVENUE as revenue,
        EVENTS.CONTACT_ID_FACT as contact_id
    )
    dimensions (
        EVENTS.ACCOUNT_ID as account_id
            with synonyms = ('account','creator','client','tenant','customer')
            comment = 'Creator/business account identifier',
        EVENTS.EVENT_DATE as event_date
            with synonyms = ('date','day','activity date')
            comment = 'Calendar date of the event',
        EVENTS.EVENT_TS as event_ts
            with synonyms = ('timestamp','event time'),
        EVENTS.EVENT_TYPE as event_type
            with synonyms = ('type','interaction type','action')
            comment = 'dm, link_click, comment, share, or follow',
        EVENTS.CHANNEL as channel
            with synonyms = ('platform','network','messaging channel')
            comment = 'instagram, facebook, whatsapp, telegram, or sms',
        EVENTS.REGION as region
            with synonyms = ('geo','geography','market'),
        EVENTS.DEVICE as device
            with synonyms = ('platform type','os'),
        EVENTS.CONTENT_ID as content_id
            with synonyms = ('content','post','asset')
            comment = 'Content item the event relates to',
        EVENTS.CAMPAIGN_ID as campaign_id
            with synonyms = ('campaign','automation')
    )
    metrics (
        EVENTS.EVENT_ROWS as COUNT(*)
            comment = 'Number of engagement event rows',
        EVENTS.TOTAL_EVENTS as SUM(events.event_count)
            comment = 'Total engagement events',
        EVENTS.UNIQUE_CONTACTS as COUNT(DISTINCT events.contact_id_fact)
            comment = 'Distinct subscribers touched -- non-additive, cannot be pre-aggregated',
        EVENTS.TOTAL_REVENUE as SUM(events.revenue)
            comment = 'Total attributed revenue',
        EVENTS.AVG_REVENUE as AVG(events.revenue),
        EVENTS.CLICK_TO_DM_RATIO as
            SUM(CASE WHEN events.event_type = 'link_click' THEN events.event_count END)
          / NULLIF(SUM(CASE WHEN events.event_type = 'dm' THEN events.event_count END), 0)
            comment = 'Click-through rate: link clicks divided by DMs -- additive components'
    )
    comment = 'Creator engagement events for interactive-analytics benchmarking';

DESCRIBE SEMANTIC VIEW IA_BENCH.BENCH.SV_ENGAGEMENT;
