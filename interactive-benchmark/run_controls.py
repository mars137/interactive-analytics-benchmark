#!/usr/bin/env python3
"""WI-22 control-corpus runner.

Runs CONTROL_SV and CONTROL_HUMAN against a chosen warehouse, tagged by QUERY_TAG for exact
extraction. Measures semantic-view expansion cost and human-vs-agent SQL patterns.
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
        paramstyle="qmark",  # corpus uses ? placeholders
    )
    cur = conn.cursor()

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
