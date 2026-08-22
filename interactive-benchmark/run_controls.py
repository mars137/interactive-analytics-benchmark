#!/usr/bin/env python3
"""
WI-22 control-corpus runner.

Runs CONTROL_SV and CONTROL_HUMAN against a chosen warehouse, tagging every statement with a
QUERY_TAG so extraction can correlate EXACTLY rather than by time window. (Time-window
correlation was necessary for the FlakeBench arms because FlakeBench does not set a tag; here we
control the driver, so we do it properly.)

Two questions this answers that the replayed agent corpus cannot:
  1. CONTROL_SV  -- what does SEMANTIC_VIEW() syntax cost at query time? An earlier probe spent
     2427ms of 2582ms (94%) in COMPILATION. The agent never emits this syntax -- it emits
     pre-expanded SQL -- so this measures what the agent's expansion SAVES.
  2. CONTROL_HUMAN -- the same questions written the way a human writes them, notably Q4 in the
     two-CTE / two-scan form, versus the agent's single-scan conditional aggregation.

Note an asymmetry in the corpus: CONTROL_SV has Q1, Q2, Q3, Q3b while CONTROL_HUMAN has Q1..Q4.
Only Q1-Q3 are directly comparable across the two sets; do not pair Q3b with Q4.
"""
import argparse, os, random, statistics, sys, time
from datetime import datetime, timezone

import snowflake.connector
from cryptography.hazmat.primitives import serialization


def private_key_der(path: str):
    with open(os.path.expanduser(path), "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--warehouse", required=True)
    ap.add_argument("--reps", type=int, default=60, help="executions per query")
    ap.add_argument("--tag-suffix", default="")
    args = ap.parse_args()

    conn = snowflake.connector.connect(
        account="SFSENORTHAMERICA-DEMO_ATAHIR",
        user="IA_BENCH_SVC",
        private_key=private_key_der("~/.snowflake/keys/ia_bench_svc.p8"),
        role="FLAKEBENCH_ROLE",
        warehouse=args.warehouse,
        database="IA_BENCH",
        schema="BENCH",
        # The corpus uses `?` placeholders (matching the agent corpus bind convention), but the
        # connector defaults to pyformat (%s) and fails with "not all arguments converted during
        # string formatting". qmark is required.
        paramstyle="qmark",
    )
    cur = conn.cursor()

    # Result cache OFF: otherwise repeated identical binds return instantly and we measure
    # nothing about the table or the warehouse.
    cur.execute("ALTER SESSION SET USE_CACHED_RESULT = FALSE")

    cur.execute("SELECT account_id FROM IA_BENCH.BENCH.ACCOUNT_POOL")
    pool = [r[0] for r in cur.fetchall()]
    if not pool:
        sys.exit("account pool is empty")

    cur.execute(
        "SELECT ctl_id, corpus, q_class, param_count, sql_text "
        "FROM IA_BENCH.BENCH.CONTROL_CORPUS ORDER BY corpus, q_class"
    )
    corpus = cur.fetchall()
    print(f"loaded {len(corpus)} control queries; pool={len(pool)}; wh={args.warehouse}")

    tag_base = f"wi22_ctl{args.tag_suffix}"
    started = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    results = {}

    for ctl_id, corpus_name, q_class, param_count, sql_text in corpus:
        key = f"{corpus_name}/{q_class}"
        tag = f"{tag_base}|{corpus_name}|{q_class}"
        cur.execute(f"ALTER SESSION SET QUERY_TAG = '{tag}'")
        lat, errs = [], 0
        for _ in range(args.reps):
            binds = [random.choice(pool) for _ in range(param_count)]
            t0 = time.perf_counter()
            try:
                cur.execute(sql_text, binds)
                cur.fetchall()
                lat.append((time.perf_counter() - t0) * 1000.0)
            except Exception as e:
                errs += 1
                if errs == 1:
                    print(f"  {key} ERROR: {str(e)[:160]}")
        if lat:
            lat.sort()
            results[key] = dict(
                n=len(lat), errs=errs,
                p50=round(statistics.median(lat)),
                p90=round(lat[int(0.90 * (len(lat) - 1))]),
                p99=round(lat[int(0.99 * (len(lat) - 1))]),
                max=round(lat[-1]),
            )
            r = results[key]
            print(f"  {key:24} n={r['n']:4} errs={errs:3} "
                  f"p50={r['p50']:6} p90={r['p90']:6} p99={r['p99']:6} max={r['max']:6}")
        else:
            print(f"  {key:24} ALL {errs} EXECUTIONS FAILED")

    cur.execute("ALTER SESSION SET QUERY_TAG = ''")
    ended = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    print(f"\nwindow: {started} -> {ended} (UTC)   tag_base={tag_base}")
    print("client-side latencies above INCLUDE driver+network overhead; use ACCOUNT_USAGE "
          "filtered on QUERY_TAG for server-side truth.")
    conn.close()


if __name__ == "__main__":
    main()
