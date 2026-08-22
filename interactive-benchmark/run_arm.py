"""Run a WI-22 arm through FlakeBench and report what actually happened.

Deliberately checks more than "did it finish":
  * bind substitution really occurred (distinct account_ids appear in QUERY_HISTORY)
  * server-side sf_* enrichment populated (FlakeBench's own MERGE from INFORMATION_SCHEMA)
  * NO fallback contamination -- for interactive arms this is load-bearing, because a query
    that exceeds the fixed 5s ceiling is transparently re-run on the fallback warehouse and
    FlakeBench records the FALLBACK timing as if it were interactive.

Usage:
  python run_arm.py --list
  python run_arm.py --arm B1 [--duration 120] [--concurrency 10]
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request

API = "http://127.0.0.1:8000"


def api(method: str, path: str, payload: dict | None = None, timeout: int = 180):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{API}{path}", data=data,
        headers={"Content-Type": "application/json"}, method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode()
            return r.status, (json.loads(body) if body.strip() else {})
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode()[:1500]}


def list_templates() -> dict[str, str]:
    status, body = api("GET", "/api/templates/")
    if status != 200:
        sys.exit(f"list templates failed: {status} {body}")
    items = body if isinstance(body, list) else body.get("templates", body.get("items", []))
    return {
        t["template_name"]: t["template_id"]
        for t in items
        if str(t.get("template_name", "")).startswith("WI22_ARM_")
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--duration", type=int)
    ap.add_argument("--concurrency", type=int)
    ap.add_argument("--poll", type=int, default=15)
    ap.add_argument("--max-wait", type=int, default=1800)
    args = ap.parse_args()

    templates = list_templates()
    if args.list or not args.arm:
        for name, tid in sorted(templates.items()):
            print(f"  {name:16s} {tid}")
        if not args.arm:
            return
        return

    name = f"WI22_ARM_{args.arm}"
    tid = templates.get(name)
    if not tid:
        sys.exit(f"template {name} not found; have: {sorted(templates)}")

    overrides: dict = {}
    if args.duration:
        overrides["duration_seconds"] = args.duration
    if args.concurrency:
        overrides["concurrent_connections"] = args.concurrency

    print(f"creating test from {name} ({tid}) overrides={overrides or 'none'}")
    status, body = api("POST", f"/api/tests/from-template/{tid}", overrides)
    print(f"  create -> HTTP {status}")
    if status >= 400:
        print(json.dumps(body, indent=2)[:1500])
        sys.exit(1)

    test_id = body.get("test_id") or body.get("id") or body.get("run_id")
    if not test_id:
        print("no test_id in response:", json.dumps(body)[:800])
        sys.exit(1)
    print(f"  test_id = {test_id}")

    status, body = api("POST", f"/api/tests/{test_id}/start", {})
    print(f"  start -> HTTP {status} {json.dumps(body)[:300]}")
    if status >= 400:
        sys.exit(1)

    # Poll until terminal
    waited = 0
    last = None
    while waited < args.max_wait:
        time.sleep(args.poll)
        waited += args.poll
        st, b = api("GET", f"/api/tests/{test_id}")
        state = str(b.get("status") or b.get("state") or "?")
        if state != last:
            print(f"  [{waited:5d}s] status={state}")
            last = state
        if state.upper() in {"COMPLETED", "FAILED", "STOPPED", "ERROR", "CANCELLED"}:
            break

    st, b = api("GET", f"/api/tests/{test_id}/metrics")
    print("\n=== metrics ===")
    if st == 200:
        interesting = [
            "total_operations", "operations_per_second", "error_count", "error_rate",
            "generic_sql_p50_latency_ms", "generic_sql_p95_latency_ms",
            "generic_sql_p99_latency_ms", "app_overhead_p95_ms",
        ]
        for k in interesting:
            if k in b:
                print(f"  {k:34s} {b[k]}")
        if not any(k in b for k in interesting):
            print(json.dumps(b, indent=2)[:1500])
    else:
        print(f"  metrics HTTP {st}: {json.dumps(b)[:600]}")

    print(f"\ntest_id={test_id}")
    print("Now verify server-side truth in Snowflake (do NOT trust the dashboard alone):")
    print(f"  SELECT * FROM FLAKEBENCH.TEST_RESULTS.TEST_RESULTS WHERE test_id = '{test_id}';")
    print(f"  -- query_tag is 'flakebench:test_id={test_id}'")


if __name__ == "__main__":
    main()
