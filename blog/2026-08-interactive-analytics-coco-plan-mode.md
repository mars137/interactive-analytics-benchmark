# Sub-Second on Four Billion Rows: What Snowflake Interactive Warehouses Actually Buy You

Snowflake's interactive warehouses promise sub-second analytics. I wanted to see what that looks like in practice on a realistic workload — not a synthetic TPC-H run, but an agentic analyst pattern: a Cortex Analyst agent answering natural-language questions over a large table.

I ran this using Cortex Code's Plan mode, where the AI proposes and I push back. Several of the most useful findings came from catching mistakes — mine and the agent's — so I've left those in.

## The setup

**Data:** 4 billion rows, 433GB, modelling creator-platform engagement events. Power-law distribution over 200K accounts (a few huge, a long tail of tiny). Three table variants: unclustered, clustered by `(account_id, event_date)`, and an `INTERACTIVE TABLE` with the same clustering key.

**Workload:** A Cortex Analyst agent answered 24 questions across four query classes. I harvested the agent's generated SQL into a frozen corpus, then replayed that corpus identically on each warehouse. Result cache disabled (`USE_CACHED_RESULT = FALSE`) so every execution hits the engine.

**Configurations tested (180 seconds per run, closed-loop):**

| Config | Warehouse | Table |
|---|---|---|
| A | Interactive XS | Clustered standard |
| C | Interactive XS | Interactive table |
| D | Interactive XS | Unclustered standard |
| E | Interactive M | Clustered standard |
| B1 | Standard Gen2 XS | Clustered standard |
| B2 | Multi-cluster XS (1–4) | Clustered standard |
| B3 | Adaptive | Clustered standard |
| F | Interactive XS vs Standard XS | Live agent (end-to-end) |

**Warming:** Each interactive run got a 10-minute query-driven warm-up (5 representative queries rotating accounts with result cache off). Achieved cache percentages were measured after the fact from `ACCOUNT_USAGE` — I couldn't gate on a live reading because `GET_QUERY_OPERATOR_STATS` returned no data for my service role, even with `MONITOR` granted.

**Correlation:** Server-side metrics from `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY`, correlated by warehouse name and time window. Controls correlated exactly by `QUERY_TAG`. All code is [on GitHub](https://github.com/mars137/interactive-analytics-benchmark).

## Results

| Config | Queries | p50 | p90 | p99 | Max | % Partitions | Cache % |
|---|--:|--:|--:|--:|--:|--:|--:|
| **A** (interactive XS, clustered) | 17,654 | **37ms** | 71 | 235 | 4,754 | 0.0074 | 63.3 |
| **C** (interactive XS, interactive table) | 11,348 | **32ms** | 64 | 237 | 4,467 | 0.0074 | 50.1 |
| **E** (interactive M, clustered) | 17,661 | **32ms** | 58 | 103 | 1,585 | 0.0074 | 87.8 |
| **D** (interactive XS, unclustered) | 340 | 8,731ms | 12,787 | 25,022 | 28,169 | 99.69 | 98.7 |
| B1 (standard Gen2 XS) | 10,150 | 85ms | 218 | 724 | 5,695 | 0.0082 | 42.2 |
| B2 (multi-cluster XS) | 9,547 | 90ms | 258 | 735 | 5,822 | 0.0083 | 35.9 |
| B3 (adaptive) | 9,490 | 95ms | 259 | 822 | 3,363 | 0.0085 | 42.3 |

**Interactive XS vs standard Gen2 XS, same data, same queries: 37ms vs 85ms at p50 (2.3x), 235ms vs 724ms at p99 (3.1x), and 74% more queries completed in the same window.**

Note: arm A ran at 63% cache vs B1's 42%, so part of this gap is warmer cache rather than warehouse type alone. Each config is a single 180-second run with no repetition — treat these as one measured ratio, not a guaranteed constant.

## What the numbers show

### 1. Interactive is meaningfully faster than standard on identical data

The 2.3x at p50 and 3.1x at p99 hold across an independent control set (480 queries per side, correlated by `QUERY_TAG`) — interactive won all eight queries at both percentiles, with tail improvements up to 4.6x.

### 2. Without clustering, interactive doesn't engage at all

Config D is the cautionary result. 266 of 340 queries (78%) executed on the **fallback warehouse**, not on interactive. They blew through the 5-second ceiling and were silently re-run on standard compute. Every one returned `SUCCESS` — no error, no warning.

The only way to detect this is checking `WAREHOUSE_TYPE` and `FAULT_HANDLING_TIME` in query history. Without that check, you'd report 8,731ms as "interactive latency" when it's actually standard-warehouse latency plus a wasted attempt.

Without a clustering key on a 4B-row table, queries scan 99.69% of partitions. Interactive mode requires that queries finish in under 5 seconds; full table scans at this scale don't qualify.

### 3. A well-clustered standard table nearly matches an interactive table

Config C (interactive table) vs config A (clustered standard table): 32ms vs 37ms at p50. At p99 they're identical (237 vs 235). The purpose-built interactive table reads less data (50% cache vs 63%), but the latency difference is negligible. Standard-table support on interactive warehouses (public preview) gets you most of the way.

### 4. Warehouse size buys tail latency, not median

Interactive M vs interactive XS: p50 32ms vs 37ms (~14%), but p99 **103ms vs 235ms** (2.3x). Both scan 0.0074% of partitions — clustering shrinks the working set far below the XS cache budget (350GB), so a bigger cache has nothing additional to hold. The extra compute helps the unlucky queries, not the typical ones.

This also explains why the 433GB table never actually overflowed XS's 350GB budget. Columnar projection means the query only reads the columns it needs. The padding columns I added to reach 433GB are never touched.

### 5. Multi-cluster and adaptive are slightly worse for single queries

B2 (90ms) and B3 (95ms) trail plain Gen2 XS (85ms) at p50. These warehouse types add concurrency capacity and elasticity — they don't make individual queries faster. At single-stream load, the extra machinery is overhead.

### 6. Compilation dominates once execution is this fast

Configs A, C, and E spend 49–62% of elapsed time in compilation. At p50, config E compiles for 19ms and executes for 11ms. At this latency scale, the query planner is the bottleneck, not the scan. The next performance win is plan caching, not more compute.

## The live agent arm: interactive doesn't help here

I pointed the live Cortex Analyst agent at interactive vs standard and measured end-to-end.

| Condition | p50 |
|---|--:|
| Agent SQL on interactive XS | 22,315ms |
| Agent SQL on standard Gen2 XS | 22,786ms |
| **Null control** (both on same warehouse) | +2,583ms noise |

The measured difference (471ms, 2.1%) is five times smaller than the noise floor of a comparison where the true difference is zero by construction. So this is **no detectable difference**.

End-to-end agent latency is ~22 seconds. The engine difference is ~48ms. The engine is 0.2% of what a user waits for — the rest is orchestration, planning, and token generation.

**If you're hoping interactive warehouses will make your Cortex Analyst agent feel faster, they won't.** Interactive pays off for direct SQL — dashboards, drilldowns, embedded analytics — where I measured 2–3x.

## Things I got wrong along the way

These are worth documenting because they're traps anyone running this kind of test would hit.

**Interactive tables are a separate privilege class.** Config C initially failed every query with `Object does not exist or not authorized`. The table had 4 billion rows. The issue: `SHOW GRANTS` returns `granted_on = INTERACTIVE_TABLE`, not `TABLE`. So `GRANT SELECT ON ALL TABLES` silently skips them. You need `GRANT SELECT ON ALL INTERACTIVE TABLES` explicitly.

**The 5-second fallback is completely silent.** No error code, no query tag, no column in the standard result. The only tells are `WAREHOUSE_TYPE != 'INTERACTIVE'` and `FAULT_HANDLING_TIME > 0` in `ACCOUNT_USAGE.QUERY_HISTORY`. If you don't check, you'll benchmark your fallback warehouse and call it interactive.

**Warm-up design matters.** My warm-up loop queried 5 fixed accounts; the workload sampled randomly from 5,000. So the cache was mostly self-warmed during measurement, not pre-warmed. No finding reverses (every config faced identical conditions), but the achieved cache fractions (36–99%) reflect this mismatch.

**`AVG()` on a ratio is wrong.** Per-query `PERCENTAGE_SCANNED_FROM_CACHE` averaged naively gave 76% for config D; bytes-weighted (as the docs recommend: `SUM(bytes*pct)/SUM(bytes)`) gave 98.7%. When scan sizes vary, the unweighted mean is meaningless.

## How it was run

All SQL, Python harness, and shell orchestrator are at [github.com/mars137/interactive-analytics-benchmark](https://github.com/mars137/interactive-analytics-benchmark). The harness:

1. Resumes the interactive warehouse (starts a 1-hour billing minimum)
2. Attaches one table variant at a time via `ALTER WAREHOUSE ... ADD TABLES`
3. Runs a 10-minute query-driven warm-up
4. Replays the frozen corpus for 180 seconds (closed-loop, result cache off)
5. Records start/end timestamps; detaches the table
6. Repeats for the next config (never suspends mid-sequence to preserve cache + avoid a new billing minimum)
7. Extracts server-side metrics from `ACCOUNT_USAGE` after the ~45 minute ingestion lag

The replay driver uses key-pair auth against a `TYPE = SERVICE` user with no password. Controls use `QUERY_TAG` for exact correlation rather than time-window matching.

---

*4B rows / 433GB on Snowflake `DEMO_ATAHIR`. Each config is a single 180-second run — no repetition, no confidence intervals. Cache fractions varied 36–99% across configs. All interactive configs screened for fallback before any number was trusted. Code and data at the link above.*
