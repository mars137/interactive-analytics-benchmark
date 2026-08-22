# WI-22 arm results

Source: `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY`, correlated by (warehouse, time window) from
`/tmp/wi22_arm_windows.tsv`, filtered to `USER_NAME='IA_BENCH_SVC'`, `QUERY_TYPE='SELECT'`.
Extraction SQL: `interactive-benchmark/sql/20-extract-arms.sql`. Each arm is a 180s closed-loop
run of the same agentic-analyst corpus (harvested Cortex Analyst SQL, replayed).

Table: 4,000,000,000 rows, ~433GB unclustered / ~400GB clustered / ~401GB interactive.

| arm | config | queries | fail | non-INT wh | fault | **p50** | p90 | p99 | max | %compile | %partitions | cache% (wtd) |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| **A** | clustered standard table, **interactive XS** | 17,654 | 0 | 0 | 0 | **37** | 71 | 235 | 4,754 | 56.8 | 0.0074 | 63.3 |
| **C** | **INTERACTIVE TABLE**, interactive XS | 11,348 | 0 | 0 | 0 | **32** | 64 | 237 | 4,467 | 49.1 | 0.0074 | 50.1 |
| **E** | clustered standard table, **interactive M** | 17,661 | 0 | 0 | 0 | **32** | 58 | 103 | 1,585 | 62.2 | 0.0074 | 87.8 |
| **D** | **NON-clustered** standard table, interactive XS | 340 | 5 | **266** | **205** | **8,731** | 12,787 | 25,022 | 28,169 | 29.2 | **99.6880** | 98.7 |
| B1 | clustered, standard **Gen2 XS** | 10,150 | 0 | (10,150) | 0 | 85 | 218 | 724 | 5,695 | 68.5 | 0.0082 | 42.2 |
| B2 | clustered, standard **multi-cluster XS** (1-4) | 9,547 | 0 | (9,547) | 0 | 90 | 258 | 735 | 5,822 | 62.2 | 0.0083 | 35.9 |
| B3 | clustered, **adaptive** | 9,490 | 0 | (9,490) | 0 | 95 | 259 | 822 | 3,363 | 73.1 | 0.0085 | 42.3 |

`non-INT wh` counts queries where `WAREHOUSE_TYPE != 'INTERACTIVE'`. For B1/B2/B3 that is every
query and is *expected* — they are standard warehouses (shown parenthesised). It is only a
fallback signal on the interactive arms A, C, D, E.

## Findings

### 1. Interactive beats standard on the same data and size — ~2.3x at p50, ~3.1x at p99

Arm A vs B1, both XS, both the same clustered table: **37ms vs 85ms** at p50, **235ms vs 724ms**
at p99, and **17,654 vs 10,150** queries completed in the same 180s (**+74% throughput**).

### 2. An interactive table beats a well-clustered standard table — but only modestly

Arm C vs A, same warehouse: p50 **32 vs 37** (~14%), p90 **64 vs 71**, p99 **237 vs 235**
(indistinguishable), max 4,467 vs 4,754. So the Public Preview support for standard tables gets
you most of the way; the purpose-built interactive table buys a modest median gain and no tail
gain here. Notably C achieved this on a *lower* cache fraction (50.1% vs 63.3%), which suggests
it needs to read less to answer the same question.

### 3. Size buys tail, not median — and this is where Manychat's XS=M comes from

Arm E (M) vs A (XS): p50 **32 vs 37** — two size doublings for ~14% at the median. But p99
**103 vs 235** and max **1,585 vs 4,754**: the tail improves ~2.3x.

The mechanism is in the `%partitions` column: **both arms scan 0.0074% of partitions.**
Clustering shrinks the working set so far that XS's 350GB cache budget never binds, so a larger
budget has almost nothing left to do for the median. What M actually buys is more compute for
the unlucky queries.

This is the empirical form of a claim I got wrong earlier and had to retract: I had asserted the
433GB table would overrun the XS budget. Columnar projection plus clustering means the hot set
is a small fraction of the table — the padding columns are never read. The measured 0.0074% says
so directly, which is far stronger evidence than my original extrapolation.

### 4. Arm D never measured interactive performance at all — it measured the fallback

**266 of 340 queries (78%) ran with `WAREHOUSE_TYPE != 'INTERACTIVE'`** and 205 carried
`FAULT_HANDLING_TIME > 0`. Every one returned `SUCCESS`. Unclustered, queries scan **99.69% of
partitions**, breach the 5s interactive ceiling, and get re-run on the fallback M warehouse.

Reporting D's 8,731ms p50 as "interactive latency" would have been flatly false — it is mostly
standard-M latency plus a wasted interactive attempt. The correct claim is: *without a clustering
key, interactive mode does not engage on a table this size; it degrades to the fallback.*
Throughput collapses in proportion: 340 queries vs A's 17,654 — **52x fewer**.

This is why the fallback screen was non-negotiable. A silent, successful fallback is
indistinguishable from a working interactive arm unless you check those two columns.

### 5. Multi-cluster and adaptive do not improve single-query latency

B2 (90ms) and B3 (95ms) are both slightly *worse* than plain Gen2 XS (85ms) at p50, and no
better at p99. Multi-cluster adds concurrency capacity and adaptive adds elasticity; neither
makes an individual query faster. At this concurrency the extra machinery is overhead, not gain.

### 6. Compile time dominates once you are this fast

Arms A/C/E spend **56.8% / 49.1% / 62.2%** of elapsed time in COMPILATION. At p50, arm E spends
19ms compiling and 11ms executing. Once execution is ~11-16ms the optimizer is the bottleneck,
so the remaining wins are in plan reuse, not scan speed. Arm D inverts this (29.2% compile,
2,834ms execute) because it is genuinely doing work.

## Arm F (live agent): the noise floor exceeds the effect size

**Real-warehouse run** (18 calls per condition, 6 questions x 3 passes):

| condition | warehouse | n | p50 | p90 | min | max |
|---|---|--:|--:|--:|--:|--:|
| interactive | IA_BENCH_INTERACTIVE_XS | 18 | **22,315** | 25,983 | 13,519 | 27,899 |
| standard | IA_BENCH_STD_GEN2_XS | 18 | **22,786** | 29,767 | 12,163 | 63,481 |

Measured difference: **-471ms (-2.1%)** in favour of interactive.

**Noise control** — the same harness with *both* conditions pointed at the same warehouse
(`COMPUTE_WH`), so the true difference is zero by construction:

| condition | warehouse | n | p50 | p90 | min | max |
|---|---|--:|--:|--:|--:|--:|
| "interactive" | COMPUTE_WH | 6 | 22,673 | 23,853 | 17,203 | 26,497 |
| "standard" | COMPUTE_WH | 6 | 20,090 | 23,823 | 14,371 | 24,233 |

Two identical conditions differed by **+2,583ms (+12.9%)**.

**So the measured effect (-471ms) is about 5x smaller than the noise floor (+2,583ms) of a
comparison known to have no effect at all.** Arm F therefore reports **no detectable
difference** — not a 2.1% win. Quoting -2.1% as a result would be quoting noise with a decimal
point on it.

Why: end-to-end agent latency is **~22 seconds**, while the engine difference this benchmark
measures is **~48ms** (arm A 37ms vs B1 85ms). The engine is **~0.2%** of what the user waits
for. Practically all of it is orchestration — planning, semantic-view resolution, tool calls,
token generation.

**Conclusion: at the agent layer, interactive vs standard is invisible.** Adopting interactive
warehouses to make a Cortex Analyst agent feel faster optimises the wrong 0.2%. Interactive pays
off in the *replayed SQL* layer — dashboards, drilldowns, direct queries — which is exactly
where arms A-E measured 2-3x.

## Control corpora: semantic-view syntax vs hand-written SQL

480 executions per side (8 queries x 60 reps), 0 errors, `QUERY_TAG`-correlated. **Client-side**
latencies below — these include ~200-300ms of driver and network overhead, which compresses all
ratios relative to the server-side arm figures. Server-side extraction by tag pending the
ACCOUNT_USAGE latency.

| query | interactive p50 | standard p50 | interactive p99 | standard p99 |
|---|--:|--:|--:|--:|
| CONTROL_HUMAN Q1 | 362 | 390 | 560 | 807 |
| CONTROL_HUMAN Q2 | 332 | 361 | 547 | 1,049 |
| CONTROL_HUMAN Q3 | 306 | 423 | 542 | 1,211 |
| CONTROL_HUMAN Q4 (two-scan) | 477 | 687 | 777 | 1,559 |
| CONTROL_SV Q1 | 335 | 431 | 488 | 1,264 |
| CONTROL_SV Q2 | 274 | 384 | 476 | 999 |
| CONTROL_SV Q3 | 347 | 471 | 699 | 1,282 |
| CONTROL_SV Q3b | 226 | 496 | 547 | 1,822 |

Interactive is faster on all 8, and the gap widens sharply at p99 (standard's tail is roughly
2-3x worse). Note `CONTROL_SV` has Q1, Q2, Q3, Q3b while `CONTROL_HUMAN` has Q1-Q4, so only
Q1-Q3 pair directly; **do not compare SV Q3b against HUMAN Q4.**

### Server-side truth (QUERY_TAG-correlated, driver overhead removed)

| corpus | q | interactive p50 | standard p50 | int p99 | std p99 | int cache% | std cache% |
|---|---|--:|--:|--:|--:|--:|--:|
| CONTROL_HUMAN | Q1 | **265** | 288 | 496 | 878 | 20.4 | 1.7 |
| CONTROL_HUMAN | Q2 | **229** | 242 | 711 | 1,069 | 17.8 | 0.0 |
| CONTROL_HUMAN | Q3 | **204** | 308 | 378 | 941 | 29.8 | 1.3 |
| CONTROL_HUMAN | Q4 (two-scan) | **342** | 562 | 647 | 1,459 | 32.9 | 0.9 |
| CONTROL_SV | Q1 | **231** | 319 | 576 | 960 | 38.8 | 5.7 |
| CONTROL_SV | Q2 | **149** | 275 | 372 | 1,030 | 35.6 | 5.2 |
| CONTROL_SV | Q3 | **254** | 351 | 517 | 1,250 | 35.7 | 4.2 |
| CONTROL_SV | Q3b | **99** | 380 | 435 | 1,985 | 40.3 | 5.3 |

Interactive wins all 8 at both p50 and p99, and **zero interactive control queries fell back**
(`non-INTERACTIVE wh` = 0 on every interactive row). The tail advantage is the striking part:
SV Q3b 435ms vs 1,985ms (**4.6x**), HUMAN Q4 647ms vs 1,459ms (2.3x).

Compile share rises on the interactive side (48-56% on the SV queries vs 34-38% on standard) —
the same pattern as the arms: once execution is fast, compilation is what remains.

### A design flaw these numbers exposed: warm-up targeted 5 accounts, the workload samples 5,000

Cache fractions here are **low** — 18-40% interactive, 0-6% standard. The cause is a mismatch I
built in: the warm-up loop queries **5 fixed accounts**, while both the control corpus and the
replay corpus draw random accounts from a **5,000-account pool**. The warm-up therefore warmed a
tiny and largely irrelevant slice, and whatever cache the measured workload enjoyed it mostly
built *itself* during measurement.

So "warm" in this benchmark largely means "self-warmed during the run" — a weaker claim than the
harness implies. It reverses no finding, because the interactive arms still win on identical
corpora, pools and data. But the absolute cache percentages are not evidence of a properly
pre-warmed cache, and a corrected design would warm from the same pool it measures.

Also: the controls' p50s (~100-560ms) sit far above the arms' (~32-95ms), and the two are **not**
comparable in absolute terms. The controls are heavier hand-written aggregations run
single-threaded with the result cache off; the arms replay narrower agent-generated SQL under
concurrency. Compare interactive-vs-standard *within* each set, never across them.


`SEMANTIC_VIEW()` syntax did **not** show the pathological compile cost an earlier one-off probe
suggested (that probe spent 2,427ms of 2,582ms in compilation). At these reps the SV queries are
comparable to, and sometimes faster than, the hand-written equivalents — so the earlier probe
was almost certainly measuring cold-start compilation, not a standing property of the syntax.
That is worth stating plainly, since it corrects an assumption I built into the corpus design.

## Caveats


- **Warm state was measured after the fact, not gated on.** The live warm gate was abandoned:
  `GET_QUERY_OPERATOR_STATS` returns 0 rows for the benchmark role even on its own queries, and
  granting `OPERATE` + `MONITOR` did not fix it. Achieved cache fractions are in the table.
- **The "20 minute" warm period is mislabelled in my own harness.** The loop credits 120s per
  iteration but each iteration actually takes ~60s of wall clock, so warming was a fixed number
  of warm *queries* (10 iterations x 5 queries = 50), not a fixed duration — roughly 10 minutes
  real, not 20. This does not invalidate the arms, because the achieved cache fractions read
  from ACCOUNT_USAGE reflect whatever warming actually happened, but the label was wrong and the
  arms were less warm than intended. It also explains part of why cache fractions vary so much
  across arms (50-88%).
- Cache % is **bytes-weighted** (`SUM(bytes*pct)/SUM(bytes)`), per the docs' own recommended
  aggregate. This matters: for arm D the unweighted average is 76% but the weighted figure is
  98.7%, and for arm A it is 96% unweighted vs 63.3% weighted. Unweighted averages of a
  per-query ratio are misleading whenever scan sizes vary.
- Cache fractions differ substantially across arms (50-88%), so these are **not** equal-warmth
  comparisons. The A/C/E ordering happens not to depend on it (C is fastest on the *lowest*
  cache fraction), but it weakens any precise ratio.
- Arm A's max is 4,754ms and B1's is 5,695ms: on the interactive arm the tail sits just under
  the 5s cliff with zero fallback, which is uncomfortably close to the edge.
- Arm D had 5 hard failures whose error text has not been inspected.
- Arm C's first attempt failed every query in 33s (no `SELECT` grant — interactive tables are a
  separate grant object class) and was re-run after the fix. Its query count (11,348) is lower
  than A/E because that re-run followed a fresh warehouse resume.
- An earlier extraction showed E at 14,803 queries vs A's 17,654 and I flagged it as
  unexplained; it was simply incomplete `ACCOUNT_USAGE` population. At full latency they are
  17,661 vs 17,654 — effectively identical. Worth remembering that this view is not merely
  delayed, it is *progressively* populated.
