"""Generate FlakeBench arm templates from the frozen replay corpus.

Key contract details:
  * workload_type must be CUSTOM; custom_queries entries need kind GENERIC_SQL
  * weight_pct is a percent 0-100 at 2dp; total must equal exactly 100.00
    (executor multiplies by 100 to get basis points, rejects != 10000)
  * Parameter strategy 'choice' takes {"strategy": "choice", "values": [...]}
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any

API = "http://127.0.0.1:8000"
CONN = "demo_atahir"
DB, SCHEMA = "IA_BENCH", "BENCH"

# arm -> (table, warehouse, note)
ARMS: dict[str, tuple[str, str, str]] = {
    "A":  ("FACT_CLUSTERED",    "IA_BENCH_INTERACTIVE_XS", "zero-copy standard table on interactive XS"),
    "B1": ("FACT_CLUSTERED",    "IA_BENCH_STD_GEN2_XS",    "size-matched standard Gen2 XS baseline"),
    "B2": ("FACT_CLUSTERED",    "IA_BENCH_STD_MCW_XS",     "multi-cluster XS baseline"),
    "B3": ("FACT_CLUSTERED",    "IA_BENCH_ADAPTIVE_WH",    "adaptive warehouse baseline"),
    "C":  ("FACT_INTERACTIVE",  "IA_BENCH_INTERACTIVE_XS", "interactive table (GA path)"),
    "D":  ("FACT_NONCLUSTERED", "IA_BENCH_INTERACTIVE_XS", "pruning cliff, depth 24448"),
    "E":  ("FACT_CLUSTERED",    "IA_BENCH_INTERACTIVE_M",  "size sweep vs arm A"),
}

SQL_COL = {
    "FACT_CLUSTERED": "sql_clustered",
    "FACT_NONCLUSTERED": "sql_nonclustered",
    "FACT_INTERACTIVE": "sql_interactive",
}


def snow_json(query: str) -> list[dict[str, Any]]:
    """Run a query via snow CLI and return rows as dicts."""
    proc = subprocess.run(
        ["snow", "sql", "-c", CONN, "--format", "json", "-q", query],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.exit(f"snow sql failed:\n{proc.stdout[-2000:]}\n{proc.stderr[-2000:]}")
    start = proc.stdout.find("[")
    if start < 0:
        sys.exit(f"no JSON in snow output:\n{proc.stdout[-2000:]}")
    return json.loads(proc.stdout[start:])


def fetch_corpus(table: str) -> list[dict[str, Any]]:
    col = SQL_COL[table]
    rows = snow_json(
        f"SELECT q_id, block_seq, q_class, {col} AS sql_text "
        f"FROM {DB}.{SCHEMA}.REPLAY_CORPUS ORDER BY q_id, block_seq"
    )
    return [
        {
            "q_id": int(r["Q_ID"]),
            "block_seq": int(r["BLOCK_SEQ"]),
            "q_class": r["Q_CLASS"],
            "sql": r["SQL_TEXT"],
        }
        for r in rows
    ]


def fetch_accounts(limit: int = 300) -> list[int]:
    rows = snow_json(
        f"SELECT account_id FROM {DB}.{SCHEMA}.ACCOUNT_POOL "
        f"ORDER BY pool_seq LIMIT {limit}"
    )
    return [int(r["ACCOUNT_ID"]) for r in rows]


def even_weights(n: int) -> list[float]:
    """Weights summing to exactly 100.00 at 2dp (executor rejects != 10000 basis points)."""
    base = int(10000 / n) / 100.0            # 2dp floor, e.g. 3.84 for n=26
    weights = [base] * n
    remainder = round(100.0 - base * n, 2)   # e.g. 0.16
    weights[0] = round(weights[0] + remainder, 2)
    assert round(sum(weights), 2) == 100.00, f"weights sum to {sum(weights)}"
    return weights


def build_config(arm: str, accounts: list[int], duration: int, concurrency: int) -> dict:
    table, warehouse, note = ARMS[arm]
    corpus = fetch_corpus(table)
    weights = even_weights(len(corpus))

    custom_queries = []
    for entry, w in zip(corpus, weights):
        custom_queries.append({
            "id": f"{entry['q_class']}_q{entry['q_id']}b{entry['block_seq']}",
            "query_kind": "GENERIC_SQL",
            "operation_type": "READ",
            "label": f"{entry['q_class']} agent block",
            "weight_pct": w,
            "sql": entry["sql"],
            "parameters": [{"strategy": "choice", "values": accounts}],
        })

    return {
        "workload_type": "CUSTOM",
        # template route reads generic_queries, not custom_queries (config_normalizer.py:73)
        "generic_queries": custom_queries,
        # must be zero: summed alongside generic weights and total must == 100.00
        "custom_point_lookup_pct": 0,
        "custom_range_scan_pct": 0,
        "custom_insert_pct": 0,
        "custom_update_pct": 0,

        # template config uses flat keys (not nested table_configs/warehouse_configs)
        "table_name": table,
        "database": DB,
        "schema": SCHEMA,
        "table_type": "INTERACTIVE" if table == "FACT_INTERACTIVE" else "STANDARD",
        "warehouse_name": warehouse,

        "duration_seconds": duration,
        "warmup_seconds": 0,
        "concurrent_connections": concurrency,
        "load_mode": "CONCURRENCY",
        "autoscale_enabled": False,   # pin concurrency fixed across arms
        "think_time_ms": 0,
        "metrics_interval_seconds": 1.0,
        "use_cached_result": False,    # must be false or later arms measure result cache
        "target_generic_sql_p95_latency_ms": 500,
        "target_generic_sql_p99_latency_ms": 1000,
        "target_generic_sql_error_rate_pct": 1.0,

        "_arm": arm,
        "_note": note,
    }


def create_template(arm: str, cfg: dict) -> None:
    import urllib.error
    import urllib.request

    body = json.dumps({
        "template_name": f"WI22_ARM_{arm}",
        "description": f"WI-22 arm {arm}: {cfg['_note']} (agent corpus, 26 queries)",
        "config": cfg,
        "tags": {"wi": "22", "arm": arm},
    }).encode()
    req = urllib.request.Request(
        f"{API}/api/templates/", data=body,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            print(f"arm {arm}: HTTP {resp.status} {resp.read()[:300].decode()}")
    except urllib.error.HTTPError as e:
        print(f"arm {arm}: HTTP {e.code}\n{e.read()[:3000].decode()}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--duration", type=int, default=180)
    ap.add_argument("--concurrency", type=int, default=10)
    args = ap.parse_args()

    if args.list:
        for a, (t, w, n) in ARMS.items():
            print(f"  {a:3s} {t:20s} {w:26s} {n}")
        return

    targets = list(ARMS) if args.all else ([args.arm] if args.arm else [])
    if not targets:
        sys.exit("specify --arm X, --all, or --list")

    accounts = fetch_accounts()
    print(f"account pool for binds: {len(accounts)} values", file=sys.stderr)

    for arm in targets:
        cfg = build_config(arm, accounts, args.duration, args.concurrency)
        if args.dry_run:
            slim = dict(cfg)
            slim["generic_queries"] = [
                {**cfg["generic_queries"][0],
                 "parameters": [{"strategy": "choice", "values": ["<300 accounts>"]}]},
                f"... {len(cfg['generic_queries']) - 1} more",
            ]
            print(json.dumps(slim, indent=2)[:3000])
            print(f"\nweights sum = {sum(q['weight_pct'] for q in cfg['generic_queries']):.2f}")
        else:
            create_template(arm, cfg)


if __name__ == "__main__":
    main()
