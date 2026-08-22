#!/usr/bin/env python3
"""WI-22 arm F: live agent latency, interactive vs standard.

Measures end-to-end user wait via DATA_AGENT_RUN. The only difference between conditions
is tool_resources.EngagementAnalyst.execution_environment.warehouse.
"""
import argparse, json, os, statistics, time
from datetime import datetime, timezone

import snowflake.connector
from cryptography.hazmat.primitives import serialization

QUESTIONS = [
    "How many unique subscribers did account 50000 touch in the last 30 days?",
    "What is the click-to-DM ratio for account 250 by channel in the last 30 days?",
    "Show the top 20 content items for account 1 by unique subscribers in the last 30 days.",
    "How did unique subscribers for account 120000 change versus the prior 30 days?",
    "How many engagement events did account 190000 have in the last 7 days?",
    "Which channel drove the most unique subscribers for account 50000 in the last 30 days?",
]

SPEC = """{
  "models": { "orchestration": "auto" },
  "orchestration": { "budget": { "seconds": 120, "tokens": 32000 } },
  "instructions": {
    "response": "You are an analytics assistant for a creator-engagement platform. Answer with concrete numbers. Always scope answers to the account and date range the user asks about.",
    "orchestration": "Use EngagementAnalyst for all quantitative questions about engagement events: counts, distinct subscribers, totals, ratios, rankings, and period-over-period comparisons."
  },
  "tools": [
    { "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "EngagementAnalyst",
        "description": "Converts natural language into SQL over the creator engagement semantic view."
    } }
  ],
  "tool_resources": {
    "EngagementAnalyst": {
      "semantic_view": "IA_BENCH.BENCH.SV_ENGAGEMENT",
      "execution_environment": { "type": "warehouse", "warehouse": "%%WH%%" }
    }
  }
}"""


def private_key_der(path):
    with open(os.path.expanduser(path), "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def run_condition(cur, label, target_wh, reps):
    # Repoint the agent to target_wh via CREATE OR REPLACE.
    cur.execute(
        "CREATE OR REPLACE AGENT IA_BENCH.BENCH.ENGAGEMENT_AGENT "
        "WITH PROFILE = '{\"display_name\": \"Engagement Analyst (benchmark)\"}' "
        "FROM SPECIFICATION $$" + SPEC.replace("%%WH%%", target_wh) + "$$"
    )
    print(f"\n=== arm F / {label}: agent SQL runs on {target_wh} ===")

    lat, errs = [], 0
    for rep in range(reps):
        for q in QUESTIONS:
            esc_q = q.replace("'", "''")
            req = json.dumps({"messages": [{"role": "user",
                                            "content": [{"type": "text", "text": q}]}]})
            req_sql = req.replace("'", "''")
            t0 = time.perf_counter()
            try:
                cur.execute(
                    "SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN("
                    f"'IA_BENCH.BENCH.ENGAGEMENT_AGENT', '{req_sql}')"
                )
                cur.fetchall()
                ms = (time.perf_counter() - t0) * 1000.0
                lat.append(ms)
                print(f"  [{label}] rep{rep+1} {ms:8.0f}ms  {q[:58]}")
            except Exception as e:
                errs += 1
                print(f"  [{label}] ERROR {str(e)[:150]}")
    if lat:
        lat.sort()
        return dict(label=label, wh=target_wh, n=len(lat), errs=errs,
                    p50=round(statistics.median(lat)),
                    p90=round(lat[int(0.90 * (len(lat) - 1))]),
                    min=round(lat[0]), max=round(lat[-1]),
                    mean=round(statistics.mean(lat)))
    return dict(label=label, wh=target_wh, n=0, errs=errs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interactive-wh", default="IA_BENCH_INTERACTIVE_XS")
    ap.add_argument("--standard-wh", default="IA_BENCH_STD_GEN2_XS")
    ap.add_argument("--reps", type=int, default=2, help="passes over the question set")
    args = ap.parse_args()

    # Requires ACCOUNTADMIN (agent ownership); must run in foreground (password from env var).
    pw = os.environ.get("SNOWFLAKE_CONNECTIONS_DEMO_ATAHIR_PASSWORD")
    if not pw:
        raise SystemExit(
            "SNOWFLAKE_CONNECTIONS_DEMO_ATAHIR_PASSWORD is not set. Arm F must run in the "
            "foreground; background shells do not inherit it."
        )
    conn = snowflake.connector.connect(
        account="SFSENORTHAMERICA-DEMO_ATAHIR",
        user="ATAHIR",
        password=pw,
        role="ACCOUNTADMIN",
        warehouse="COMPUTE_WH",
        database="IA_BENCH",
        schema="BENCH",
        paramstyle="qmark",
    )
    cur = conn.cursor()
    started = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    out = [run_condition(cur, "interactive", args.interactive_wh, args.reps),
           run_condition(cur, "standard", args.standard_wh, args.reps)]

    ended = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    print(f"\n=== arm F summary (window {started} -> {ended} UTC) ===")
    for r in out:
        if r["n"]:
            print(f"  {r['label']:12} wh={r['wh']:24} n={r['n']:3} errs={r['errs']} "
                  f"p50={r['p50']}ms p90={r['p90']}ms min={r['min']}ms max={r['max']}ms")
        else:
            print(f"  {r['label']:12} wh={r['wh']:24} NO SUCCESSFUL RUNS (errs={r['errs']})")
    if all(r["n"] for r in out):
        d = out[0]["p50"] - out[1]["p50"]
        print(f"\n  interactive - standard at p50: {d:+d}ms "
              f"({100.0*d/out[1]['p50']:+.1f}%)")
        print("  Compare against the replay arms (A 37ms vs B1 85ms server-side): if this "
              "delta is far smaller in relative terms, agent overhead dominates the engine.")
    conn.close()


if __name__ == "__main__":
    main()
