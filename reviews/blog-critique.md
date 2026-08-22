# Cold Critique: Blog Post vs RESULTS.md

## Summary

The blog post is numerically faithful — every derived figure checks out against the source data. The problems are structural: the headline causal claim (interactive 2.3x faster) is confounded by a large cache-fraction difference the post never mentions; several RESULTS.md caveats are absent or softened; and the "size buys the tail, not the median" finding lacks any uncertainty language despite a single unrepeated run per arm.

---

## A. NUMERIC FIDELITY

All derived numbers verified correctly:

| Claim | Computation | Result |
|---|---|---|
| 2.3x (37 vs 85) | 85/37 = 2.30 | ✓ |
| 3.1x (235 vs 724) | 724/235 = 3.08 | ✓ rounds to 3.1x |
| 74% more queries (17,654 vs 10,150) | (17654-10150)/10150 = 73.9% | ✓ |
| 52 times fewer (340 vs 17,654) | 17654/340 = 51.9 | ✓ |
| ~14% (32 vs 37) | (37-32)/37 = 13.5% | ✓ |
| 0.2% (48ms vs ~22,000ms) | 48/22000 = 0.22% | ✓ (48 = 85-37) |
| five times larger (471 vs 2,583) | 2583/471 = 5.48 | ✓ rounds to ~5x |
| 4.6x (435 vs 1,985) | 1985/435 = 4.56 | ✓ |
| 49-62% compile | A=56.8, C=49.1, E=62.2 | ✓ |

**No numeric mismatches found.** One minor note: the blog says "five times larger" but the ratio is 5.48x — directionally correct and labeled imprecisely rather than inaccurately, since the post uses it qualitatively ("the noise floor was five times larger"). Defensible.

---

## B. OVERCLAIMING

### MUST FIX

**B1.** The headline interactive-vs-standard comparison (A vs B1) is confounded by radically different cache fractions.

- File: blog post, line 104
- Quote: "Interactive vs standard, same size, same data: 37ms vs 85ms at p50 (2.3x), 235ms vs 724ms at p99 (3.1x)"
- Problem: RESULTS.md shows arm A cache% = 63.3% and B1 cache% = 42.2%. That is a 50% relative difference in cache hit rate. The post's causal framing ("interactive vs standard") implies the warehouse type is the single cause of the gap. But a 21-percentage-point cache advantage confounds the comparison. RESULTS.md itself flags this: "Cache fractions differ substantially across arms (50-88%), so these are **not** equal-warmth comparisons." The blog does not mention this caveat at all for the headline comparison.
- Confidence: HIGH — the data is unambiguous.
- Suggested fix: After the quoted sentence, add something like: "Caveats: arm A ran at 63% cache versus B1's 42%, so part of the gap is attributable to warmer cache on the interactive run rather than the warehouse type alone. No arm was repeated, so I cannot decompose the effect."

**B2.** "Size buys the tail, not the median" is stated as a general finding from a single unrepeated run.

- File: blog post, lines 120-122
- Quote: "Size buys the tail, not the median."
- Problem: This is presented as a discovered law. The data is one run of arm E and one run of arm A, with no repetition and no confidence intervals. RESULTS.md section 3 uses the same bold framing. A 5ms difference at p50 (37 vs 32) could easily be noise — the controls showed 2,583ms of noise in a null comparison at the agent layer, and even for replayed SQL, the blog never establishes that 5ms at p50 is distinguishable from run-to-run variance.
- Confidence: MEDIUM — the tail result (103 vs 235 at p99) is large enough to likely survive repetition; the median claim (37 vs 32 is "only ~14%") is the weak link.
- Suggested fix: "On this single run, size improved the tail substantially (p99 103ms vs 235ms) and the median barely at all (32 vs 37ms). Without repetition I can't establish a confidence interval, but the tail difference is large enough to be suggestive."

**B3.** "A well-clustered standard table gets you most of the way" — stated from a comparison where arm C completed 36% fewer queries.

- File: blog post, lines 114-115
- Quote: "a well-clustered standard table gets you most of the way"
- Problem: Arm C completed 11,348 queries vs A's 17,654 — 36% fewer. RESULTS.md notes this is because C was re-run after a grants failure and a fresh warehouse resume. But fewer queries means C's cache was built over fewer iterations in the same time window, and its latency distribution is drawn from a different throughput regime. The p50 comparison (32 vs 37) is between populations of very different sizes under different self-warming trajectories. The blog doesn't mention the query-count gap or its cause in this section.
- Confidence: MEDIUM — the caveat is in RESULTS.md and the blog table, but the prose conclusion ignores it.
- Suggested fix: Add a sentence: "Arm C completed fewer queries (11,348 vs 17,654) due to a re-run after a grants fix, so this is not a perfectly controlled comparison."

### SHOULD FIX

**B4.** The SEMANTIC_VIEW() cold-start correction risks over-generalising.

- File: blog post — this claim is actually *absent* from the blog. RESULTS.md line 178-181 says: "the earlier probe was almost certainly measuring cold-start compilation, not a standing property of the syntax."
- Problem: The blog does not discuss SEMANTIC_VIEW() compile cost at all. This is not overclaiming — it is simply absent. No issue here.
- Confidence: N/A — the concern in the task prompt does not apply; the blog omits rather than overclaims.

**B5.** The blog table (line 96-102) omits `cache% (wtd)` and `%compile` columns that are present in RESULTS.md. This makes the prose claims about those metrics uncheckable by the reader against the displayed data.

- Confidence: LOW — this is a presentation choice, not a factual error, but it means the reader cannot verify the confounding issue.

---

## C. OMITTED CAVEATS

### MUST FIX

**C1.** The 5-accounts-vs-5000-pool warm mismatch is mentioned (blog lines 199-203) but only in the "four more things that bit me" section, framed as a harness bug. It is NOT mentioned in the headline comparison section where it actually matters (lines 93-105). The reader sees "37ms vs 85ms" without knowing the interactive arm had 50% more cache.

- RESULTS.md quote: "Cache fractions differ substantially across arms (50-88%), so these are **not** equal-warmth comparisons."
- Blog: Absent from the findings section entirely. The warm-up anecdote on line 199 does not connect to the headline numbers.
- Suggested fix: In the comparison table or immediately after line 105, state the cache percentages and acknowledge they confound the ratio.

**C2.** No arm was repeated.

- RESULTS.md: Implicit throughout (each arm is "a 180s closed-loop run" — singular), and the caveats section says "Cache fractions differ substantially" without ever noting repetition would resolve it.
- Blog: Never states this. Every finding is presented as definitive.
- Suggested fix: State once, prominently (e.g., in the endnote at line 229): "Each arm is a single 180-second run with no repetition. I have no confidence intervals."

**C3.** Arm D's 5 unexplained hard failures.

- RESULTS.md line 206: "Arm D had 5 hard failures whose error text has not been inspected."
- Blog: Line 74 says "queries | non-INTERACTIVE | fault handled | p50" but the "fail" column from RESULTS.md (which shows 5) is dropped from the blog table entirely.
- Suggested fix: Mention in the arm D discussion: "5 of 340 queries hard-failed for reasons I haven't inspected."

### SHOULD FIX

**C4.** The "20 min really 10 min" warm mislabel.

- RESULTS.md lines 192-196: "The '20 minute' warm period is mislabelled in my own harness... roughly 10 minutes real, not 20."
- Blog: Never mentions this. Lines 196-203 talk about warming the wrong data but not the duration mislabel.
- Suggested fix: Could be folded into the warm-up anecdote on line 199: "and the warm-up ran for roughly 10 minutes, not the 20 my harness claimed."

**C5.** Controls-vs-arms non-comparability.

- RESULTS.md lines 172-175: "the controls' p50s (~100-560ms) sit far above the arms' (~32-95ms), and the two are **not** comparable in absolute terms."
- Blog: The controls are never mentioned numerically in the blog post except for the 4.6x figure which is controls-internal (SV Q3b interactive vs standard). This is fine — the blog doesn't cross-compare. But the 4.6x figure appears nowhere in the blog's text; I was checking it from the task prompt. Let me re-read... The 4.6x is indeed not in the blog post. It was only in the task prompt's list of derived claims to check.
- Confidence: LOW — the blog doesn't make the cross-comparison, so there's nothing to fix.

---

## D. INTERNAL CONTRADICTION

**D1.** Blog line 98 says arm C has "0.0074" for % partitions. RESULTS.md confirms this. Blog line 113 says "It did that on a *lower* cache fraction" — correct (50.1% vs 63.3%). No contradiction here.

**D2.** Blog line 86 says "Fifty-two times fewer" comparing 340 to 17,654. RESULTS.md section 4 says "52x fewer." Both say the same thing. ✓

**D3.** Blog line 147 says "At p50, arm E compiles for 19ms and executes for 11ms." RESULTS.md shows arm E p50 = 32ms, compile% = 62.2%. 32 * 0.622 = 19.9ms compile, 32 * 0.378 = 12.1ms execute. The blog says "19ms compile, 11ms execute" = 30ms total vs the 32ms p50. This is not a contradiction — compile% is an average across all queries, not the p50 query specifically — but the blog implies these are p50 figures when they are really (average_compile_share × p50). This is a minor imprecision, not a contradiction.

**No hard internal contradictions found.**

---

## DEFENSIBLE AS WRITTEN

- The arm D narrative (78% fallback, 99.69% partitions, "52x fewer") — all numbers check, framing is appropriately strong.
- "The engine is 0.2% of what the user waits for" — arithmetic checks (48ms / 22,000ms ≈ 0.2%).
- The noise-floor argument ("five times larger than the effect") — 2,583 / 471 = 5.48x, directionally correct.
- The multi-cluster/adaptive finding (B2=90, B3=95 > B1=85) — straightforward and appropriately limited ("at this concurrency").
- The compile-time-dominates finding (49-62%) — directly from data, properly scoped to "arms A, C and E."
- The interactive-table grants anecdote — factual, not a data claim.
- The warm-up-gate bug anecdote — factual narrative.

---

## Verdict: NEEDS CHANGE

The post is unusually honest for a benchmark write-up — it leads with its own errors, screens for fallback, and runs a null comparison. But its central claim (2.3x/3.1x) is presented without the single most important caveat in its own data file: the cache fractions differ by 21 percentage points. That's the kind of confound that, in a peer-reviewed context, would require either controlling for or prominently disclosing. The fix is not to retract the claim — interactive almost certainly is faster — but to hedge the magnitude and show the reader the confound.
