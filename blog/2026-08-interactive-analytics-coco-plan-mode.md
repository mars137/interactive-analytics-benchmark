# Sub-Second on Four Billion Rows: Learning Snowflake Interactive Analytics with CoCo Plan Mode

I wanted to learn Snowflake's new interactive warehouses properly — not read the docs and nod,
but actually measure them and be able to say what they do and don't buy you. So I did it the way
I've been doing most hard things lately: in Cortex Code's Plan mode, with the agent coaching
rather than authoring.

The rule I set was simple. The agent doesn't get to hand me a benchmark. It has to argue for
choices, and I get to push back. Every time I pushed back and it turned out I was right, that
became a lesson. Every time it pushed back and *it* was right, that became a better lesson.

We ended up with 4 billion rows, 433GB, nine warehouse configurations, and a pile of results —
several of which contradicted what one of us confidently predicted at the start.

---

## The first thing I did was catch it being wrong

The plan opened with an arm comparing an XS interactive warehouse against an M. Interactive
warehouses have a fixed local cache budget — XS gets 350GB, M gets 1.2TB — so the pitch was
that a table big enough to overflow XS would show M pulling ahead.

The plan asserted our table would overflow XS. I asked the obvious question:

> The XS-vs-M arm only means something if the working set fits XS. How did you determine this?

It folded, and correctly. The cache budgets were straight from the docs, but the claim that our
data would exceed 350GB was an extrapolation it had made up. When it actually worked the numbers,
the realistic hot set was something like 30-60GB — nowhere near the budget. The arm as designed
would have compared two warehouses that both fit everything comfortably, and then I'd have
written "size doesn't matter" on the basis of a test that couldn't have shown otherwise.

**Ask where a number came from.** Not because agents lie, but because a sourced fact and an inference built on top of it look identical in prose. "XS gets 350GB" and "our table will
exceed it" were the same confident sentence, and only one of them was real.

So we rebuilt the dataset: widen the row to ~100 bytes and push to 4 billion rows, 433GB. Enough
to actually exceed the budget.

Except — spoiler — it still didn't. More on that shortly, because that failure turned out to be
the most interesting result in the whole exercise.

## Building something worth measuring

The workload had to be an *agentic analyst* pattern, because that's what people are actually
building now. So:

- A purpose-built semantic view over the fact table
- A Cortex Analyst agent on top of it
- 24 natural-language questions across four query classes, spanning a power-law account
  distribution (a handful of enormous accounts, a long tail of tiny ones — like real data)
- The agent's generated SQL **harvested** into a frozen corpus, so every warehouse configuration
  replays byte-identical queries
- Plus a separate arm that runs the **live agent**, to measure what a user actually waits for

That harvest-and-replay split matters. Replay isolates the engine. The live arm measures the
experience. They answer different questions, and conflating them is how you end up claiming a
warehouse upgrade made your chatbot fast.

## The safety rail that earned its place

Interactive warehouses have a hard 5-second statement ceiling. Breach it and the query is re-run
on a fallback warehouse. Here's the part that matters: **it returns `SUCCESS`.** No error, no
warning. In query history it looks like a completely normal interactive result.

I insisted every interactive arm be screened for this before I'd trust a single latency number —
checking `WAREHOUSE_TYPE != 'INTERACTIVE'` and `FAULT_HANDLING_TIME > 0`.

Then arm D came in: the same 4-billion-row table with **no clustering key**, on interactive XS.

| | queries | non-INTERACTIVE | fault handled | p50 | partitions scanned |
|---|--:|--:|--:|--:|--:|
| Arm D | 340 | **266** | **205** | 8,731ms | **99.69%** |

**266 of 340 queries — 78% — never ran on the interactive warehouse at all.** Unclustered, the
queries scanned 99.69% of partitions, blew through 5 seconds, and got quietly re-run on a
standard M warehouse. Every one reported success.

Without that screen I'd have published "interactive warehouse: 8,731ms p50" as a finding. It
isn't interactive latency. It's mostly standard-M latency plus a wasted interactive attempt.

The real finding is sharper: **without a clustering key, interactive mode doesn't engage on a table this size. It degrades to your fallback.** Throughput tells the same story:
340 queries where the clustered arm did 17,654. Fifty-two times fewer.

**Know what a silent failure looks like in your telemetry before you start measuring.** A benchmark that can't detect its own degradation isn't a benchmark.

## What interactive actually buys

With clustering, on identical data and corpora:

| arm | config | queries | fail | **p50** | p90 | p99 | % partitions | cache % |
|---|---|--:|--:|--:|--:|--:|--:|--:|
| **A** | clustered table, **interactive XS** | 17,654 | 0 | **37ms** | 71 | 235 | 0.0074 | 63.3 |
| **C** | **interactive table**, interactive XS | 11,348 | 0 | **32ms** | 64 | 237 | 0.0074 | 50.1 |
| **E** | clustered table, **interactive M** | 17,661 | 0 | **32ms** | 58 | 103 | 0.0074 | 87.8 |
| B1 | clustered table, standard Gen2 XS | 10,150 | 0 | 85ms | 218 | 724 | 0.0082 | 42.2 |
| B2 | standard multi-cluster XS | 9,547 | 0 | 90ms | 258 | 735 | 0.0083 | 35.9 |
| B3 | adaptive warehouse | 9,490 | 0 | 95ms | 259 | 822 | 0.0085 | 42.3 |
| D | unclustered, interactive XS | 340 | **5** | 8,731ms | 12,787 | 25,022 | 99.69 | 98.7 |

**Interactive vs standard, same size, same data: 37ms vs 85ms at p50 (2.3x), 235ms vs 724ms at
p99 (3.1x), and 74% more queries completed in the same window.**

Now the honesty tax on that headline, because it's real: **arm A ran at a 63.3% cache fraction
and B1 at 42.2%.** That's a 21-point gap, and part of the difference I just attributed to
warehouse type is instead the interactive arm running warmer. I can't decompose the two, because
**each arm is a single 180-second run with no repetition — I have no confidence intervals for any
number in this post.** The direction of the result is not in doubt (interactive won on every
query in an independent control set too, below), but treat "2.3x" as this run's ratio, not a
constant.

Also visible above: arm D logged **5 hard failures** whose error text I never went back and
inspected. And arm C completed **11,348 queries against A's 17,654** — it was re-run after a
grants failure, on a freshly resumed warehouse, so it self-warmed over fewer iterations. Its
comparison against A is the least controlled in the table.

Now the results that surprised me.

### The interactive table barely beat a well-clustered standard table

Standard-table support on interactive warehouses is in public preview, and I assumed the
purpose-built `INTERACTIVE TABLE` would be meaningfully ahead. It wasn't: 32ms vs 37ms at p50,
and at p99 they're indistinguishable (237 vs 235). It did that on a *lower* cache fraction (50.1%
vs 63.3%), which hints it reads less to answer the same question.

So on this evidence **a well-clustered standard table gets you most of the way** — with the
caveat above that arm C is the weakest-controlled arm I ran. That conclusion deserves a rerun
before anyone leans on it.

### Doubling size twice bought 14% at the median

Arm E (M) vs arm A (XS): p50 32ms vs 37ms. Two size doublings, ~14% — and 5ms at p50 is small
enough that on a single unrepeated run I would not defend it as a real difference at all.

The tail is where something clearly happens: p99 **103ms vs 235ms**, max 1,585ms vs 4,754ms.
That gap is large enough to likely survive repetition. So, stated properly: **on this run, size
improved the tail substantially and the median barely or not at all.** Note E also had the
warmest cache of any arm (87.8%), which pushes in the same direction.

And here's the mechanism — it's in the `% partitions` column. **Both arms scan 0.0074% of
partitions.**


That's the payoff from my very first correction. Clustering shrinks the working set so far that
XS's 350GB budget never binds, no matter that the table is 433GB. Columnar projection means the
padding columns I added to inflate the row are *never read*. I could not make the cache overflow
by making the table bigger, because the query doesn't touch most of it.

This also explains a published result I'd been puzzling over — a benchmark on ~1B rows where XS
and M performed identically. It's the same mechanism. When your working set is a rounding error
against your cache budget, cache budget isn't your constraint.

**The measurement that refuses to reproduce your hypothesis is often the finding.**
I set out to prove cache pressure matters and instead measured why it usually doesn't.

### Multi-cluster and adaptive made single queries slightly *worse*

B2 (90ms) and B3 (95ms) both trailed plain Gen2 XS (85ms) at p50. Multi-cluster adds concurrency
capacity; adaptive adds elasticity. Neither makes an individual query faster, and at this
concurrency the extra machinery is pure overhead. Obvious in hindsight. Not obvious to me when I
listed the arms.

### Once you're this fast, the optimizer is the bottleneck

Arms A, C and E spend **49-62% of elapsed time in compilation.** At p50, arm E compiles for 19ms
and executes for 11ms. The scan is no longer the problem — planning is. Which means the next win
isn't a bigger warehouse, it's plan reuse.

## The arm that measured nothing, and how I knew

Then the live agent arm. Real questions, real Cortex Analyst, agent's SQL pointed at interactive
vs standard.

Interactive p50 **22,315ms**. Standard p50 **22,786ms**. Interactive wins by 471ms, 2.1%.

I nearly wrote that down. Instead I ran the same harness with **both conditions pointed at the
same warehouse** — where the true difference is, by construction, exactly zero.

That control came back **+2,583ms. +12.9%.**

**The noise floor was five times larger than the effect I'd just "measured."** So the honest
result for this arm is *no detectable difference* — not a 2.1% win.

The reason is brutal arithmetic. End-to-end agent latency is ~22 seconds. The engine difference
this entire benchmark exists to measure is ~48 milliseconds. **The engine is 0.2% of what the
user waits for.** Everything else is orchestration: planning, semantic-view resolution, tool
calls, token generation.

**If you are adopting interactive warehouses to make your Cortex Analyst agent feel faster, you
are optimising the wrong 0.2%.** Interactive earns its keep in the replayed-SQL layer —
dashboards, drilldowns, direct queries — where I measured 2-3x. Not in the agent's response time.

**Run the null comparison.** Point both arms at the same thing and see what "nothing" measures. If you haven't, you don't know whether your result is a result.

## Four more things that bit me

**Interactive tables are a separate grant class.** Arm C failed every query in 33 seconds with
`Object 'IA_BENCH.BENCH.FACT_INTERACTIVE' does not exist or not authorized`. The table existed
with 4 billion rows in it. My setup had run `GRANT SELECT ON ALL TABLES` and `ON FUTURE TABLES` —
and `SHOW GRANTS` explains why that wasn't enough:

```
privilege OWNERSHIP | granted_on INTERACTIVE_TABLE | grantee ACCOUNTADMIN
```

`granted_on` is `INTERACTIVE_TABLE`, not `TABLE`. Bulk and future TABLE grants silently skip
them. You need `GRANT SELECT ON ALL INTERACTIVE TABLES` explicitly. The error text points you at
a typo; the actual problem is a privilege class you didn't know existed.

**My warm-up gate failed open.** I built a gate to wait until the cache plateaued before
measuring. It used `-1` as a sentinel for "stats unavailable" — then compared that sentinel as if
it were a cache value. Three unknowns in a row looked like a plateau, and the gate cheerfully
declared steady state at *negative one*, starting measurement at 9.5% warm. A gate that fails
open is worse than no gate, because it reports success.

**My warm-up warmed the wrong data.** The loop warmed 5 fixed accounts. The workload samples
randomly from **5,000**. So warming touched a slice the measurement barely used, and whatever
cache the runs enjoyed they mostly built themselves mid-measurement. "Warm" in my harness turned
out to mean "self-warmed during the run." No finding reverses — every arm faced identical
conditions — but I can't claim a properly pre-warmed cache, and I'd fix that design next time.

**An unweighted average of a ratio is a trap.** Averaging per-query cache percentage gave arm D
76%; weighting by bytes scanned — as the docs actually recommend — gave 98.7%. When scan sizes
vary wildly, the unweighted mean is meaningless. Snowflake documents the correct aggregate;
I'd reached for `AVG()` on autopilot.

## What Plan mode was actually good for

Not writing code. The agent wrote plenty, and most of it worked, but that wasn't the value.

The value was that a plan is *inspectable before it costs anything*. The cache-budget error was
sitting in a plan document where one question exposed it. Had it been buried in a working script,
I'd have run it, gotten clean-looking numbers from an arm that couldn't answer its own question,
and never known.

The pattern that kept paying off: **make it state the mechanism, not just the expectation.** "M
will be faster" is unfalsifiable hand-waving. "M will be faster *because* the working set exceeds
XS's 350GB budget" is a claim with a checkable premise — and that premise was wrong, which I
could only discover because it had been made explicit.

The corrections in this post aren't incidental to the learning. They *are* the learning. Every
number I trust here, I trust because something else got caught being wrong first.

---

*Benchmark harness, SQL, and full results: 4B rows / 433GB on Snowflake, nine warehouse
configurations, harvested Cortex Analyst corpus replayed identically across arms. **Each arm is a
single 180-second run with no repetition, so there are no confidence intervals anywhere in this
post**, and cache fractions varied 36-99% across arms, so none of these are equal-warmth
comparisons. All arms screened for fallback; all caveats — including the two harness bugs above —
documented alongside the results rather than quietly fixed. The control-corpus figures are
server-side and not comparable in absolute terms to the arm figures, which replay different SQL
under concurrency.*
