"""Generate FlakeBench arm templates from the frozen replay corpus.

Contract notes (all learned from reading the code, not guessed):
  * The executor reads scenario.custom_queries, and requires workload_type = CUSTOM
    (backend/models/test_config.py:323, :370-373).
  * Each entry: kind/query_kind = GENERIC_SQL, id, operation_type READ|WRITE, sql,
    weight_pct, parameters[] (backend/core/test_executor.py:_init_custom_workload).
  * IMPORTANT: weight_pct is a PERCENT 0-100 rounded to 2dp; the code multiplies by 100
    to get basis points and then requires the total to be EXACTLY 10000. So the percents
    must sum to exactly 100.00 -- naive equal division of 26 queries does not.
  * Parameter strategy 'choice' takes {"strategy": "choice", "values": [...]}.

Usage:
  python gen_templates.py --list                 # show planned arms
  python gen_templates.py --arm A --dry-run      # print config JSON only
  python gen_templates.py --arm A                # create via API
  python gen_templates.py --all                  # create all arms
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
    """Run a query via the snow CLI and return rows as dicts.

    The snow CLI prefers env vars over connections.toml, and a stale empty
    SNOWFLAKE_PASSWORD breaks it, so the caller must run with a clean environment.
    """
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
    """Weights summing to EXACTLY 100.00 at 2dp.

    Required because the executor converts percent->basis points and rejects any total
    that is not exactly 10000. Equal division of 26 leaves a 0.16 remainder, which is
    pushed onto the first entry.
    """
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
            # single bind: account_id, drawn from the skew-weighted pool
            "parameters": [{"strategy": "choice", "values": accounts}],
        })

    return {
        "workload_type": "CUSTOM",

        # The TEMPLATE route reads `generic_queries` (config_normalizer.py:73,140), NOT
        # `custom_queries` -- that is the SCENARIO field the executor reads later. Using the
        # wrong one yields "Custom query weights must sum to 100.00 (currently 0.00)" because
        # the generic list comes through empty.
        "generic_queries": custom_queries,

        # The four shortcut pct fields are summed ALONGSIDE the generic weights and the total
        # must be exactly 100.00 (config_normalizer.py:142-148). Zero them explicitly so the
        # generics own the whole distribution.
        "custom_point_lookup_pct": 0,
        "custom_range_scan_pct": 0,
        "custom_insert_pct": 0,
        "custom_update_pct": 0,

        # Target object. NOTE: the template config uses FLAT keys, not the nested
        # table_configs/warehouse_configs lists from the TestScenario model. The registry
        # reads cfg["table_name"], cfg["database"], cfg["schema"], cfg["table_type"] and
        # cfg["warehouse_name"] (backend/core/test_registry.py:116-157) and raises
        # "table_name is required" / "warehouse_name is required" otherwise.
        # FlakeBench never creates tables, so all of these must already exist.
        "table_name": table,
        "database": DB,
        "schema": SCHEMA,
        "table_type": "INTERACTIVE" if table == "FACT_INTERACTIVE" else "STANDARD",
        "warehouse_name": warehouse,

        "duration_seconds": duration,
        "warmup_seconds": 0,          # warming is handled out of band, deliberately
        "concurrent_connections": concurrency,
        "load_mode": "CONCURRENCY",
        # The normaliser defaults autoscale_enabled to TRUE. Left on, FlakeBench would vary
        # concurrency during a run, so arms would not be comparable to each other. Pin it off:
        # every arm must face exactly the same fixed c=N.
        "autoscale_enabled": False,
        "think_time_ms": 0,           # shipped OLAP template used 1000ms; wrong for sub-second
        "metrics_interval_seconds": 1.0,

        # MUST be false or later arms measure the result cache, not the data cache
        "use_cached_result": False,

        # Retargeted from the shipped olap_analytics.yaml values of 5000/10000 ms, which
        # exceed the interactive warehouse's entire 5s ceiling and would pass trivially.
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
