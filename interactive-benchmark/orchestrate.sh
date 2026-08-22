#!/usr/bin/env bash
# WI-22 arm orchestrator: attach -> warm -> run -> detach, per arm, unattended.
# Each arm gets its own variant attached (co-attaching would let variants evict each other).
# Detach/attach costs warming time but NOT a new billing period (warehouse never suspended).
# Records start/end timestamps to /tmp/wi22_arm_windows.tsv for extraction correlation.

set -uo pipefail

# Clear env vars that override connections.toml (stale FlakeBench .env breaks auth)
unset SNOWFLAKE_PASSWORD SNOWFLAKE_USER SNOWFLAKE_ACCOUNT SNOWFLAKE_ROLE \
      SNOWFLAKE_WAREHOUSE SNOWFLAKE_DATABASE SNOWFLAKE_SCHEMA \
      SNOWFLAKE_PRIVATE_KEY_PATH SNOWFLAKE_PRIVATE_KEY_PASSPHRASE

CONN=demo_atahir
DUR=${DUR:-180}
WINDOWS=/tmp/wi22_arm_windows.tsv
LOG=/tmp/wi22_orchestrate.log
MAX_WARM_SECS=${MAX_WARM_SECS:-1500}

# Use IA_BENCH_SVC key pair (works in background shells; password-based auth does not).
SF_ARGS=(--temporary-connection
         --account SFSENORTHAMERICA-DEMO_ATAHIR
         --user IA_BENCH_SVC
         --private-key-file "$HOME/.snowflake/keys/ia_bench_svc.p8"
         --authenticator SNOWFLAKE_JWT
         --role FLAKEBENCH_ROLE
         --warehouse COMPUTE_WH)

sf() { snow sql "${SF_ARGS[@]}" -q "$1" >>"$LOG" 2>&1; }

# Extract last result set's first value from multi-statement `snow sql --format json`.
sfq() {
    snow sql "${SF_ARGS[@]}" --format json -q "$1" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
while isinstance(d, list) and d and isinstance(d[-1], list):
    d = d[-1]
if isinstance(d, list) and d and isinstance(d[0], dict):
    print(list(d[0].values())[0])
else:
    print("")
' 2>/dev/null
}

warm_probe() {
    # Returns avg pct_from_cache (0-1) for a representative query; retries if stats unavailable.
    local table="$1" wh="$2" attempt v
    for attempt in 1 2 3; do
        v=$(sfq "
          ALTER SESSION SET USE_CACHED_RESULT = FALSE;
          USE WAREHOUSE ${wh};
          SELECT COUNT(*) FROM IA_BENCH.BENCH.${table}
           WHERE account_id = 50000 AND event_date >= '2026-07-24';
          SET pid = (SELECT LAST_QUERY_ID());
          SELECT COALESCE(ROUND(AVG(OPERATOR_STATISTICS:io:percentage_scanned_from_cache::FLOAT),4), -1)
          FROM TABLE(GET_QUERY_OPERATOR_STATS(\$pid)) WHERE OPERATOR_TYPE='TableScan';")
        [ -z "$v" ] && v=-1
        # accept only a real, non-negative reading
        if [ "$(python3 -c "print(1 if float('$v') >= 0 else 0)" 2>/dev/null)" = "1" ]; then
            echo "$v"; return 0
        fi
        sleep 10
    done
    echo "-1"
}

wait_warm() {
    # Fixed-duration warm-up: GET_QUERY_OPERATOR_STATS returns 0 rows for IA_BENCH_SVC even
    # with OPERATE+MONITOR, so we can't gate on a live measurement. Instead warm for a fixed
    # period with representative queries; achieved cache % is read from ACCOUNT_USAGE later.
    local table="$1" wh="$2" waited=0
    echo "    warming ${table} on ${wh} for ${MAX_WARM_SECS}s (query-driven, fixed duration)"
    while [ "$waited" -lt "$MAX_WARM_SECS" ]; do
        # Rotate accounts to warm a spread of micropartitions.
        for acct in 1 250 50000 120000 190000; do
            sf "ALTER SESSION SET USE_CACHED_RESULT = FALSE;
                USE WAREHOUSE ${wh};
                SELECT COUNT(*) AS c, COUNT(DISTINCT contact_id) AS dc
                FROM IA_BENCH.BENCH.${table}
                WHERE account_id = ${acct} AND event_date >= '2026-07-24';"
        done
        waited=$((waited+120))
        printf '    warmed %ss / %ss\n' "$waited" "$MAX_WARM_SECS"
        sleep 5
    done
    echo "    warm period complete (achieved cache % will be read from ACCOUNT_USAGE later)"
}

run_arm() {
    local arm="$1" table="$2" wh="$3" interactive="$4"
    echo "=== ARM $arm : $table on $wh ==="

    if [ "$interactive" = "yes" ]; then
        echo "  attaching $table"
        sf "ALTER WAREHOUSE ${wh} ADD TABLES (IA_BENCH.BENCH.${table});"
        wait_warm "$table" "$wh"
    fi

    local start; start=$(date -u +"%Y-%m-%d %H:%M:%S")
    echo "  running (${DUR}s test; expect ~15min incl. post-processing)"
    python3 interactive-benchmark/run_arm.py --arm "$arm" --duration "$DUR" >>"$LOG" 2>&1
    local end; end=$(date -u +"%Y-%m-%d %H:%M:%S")
    printf '%s\t%s\t%s\t%s\t%s\n' "$arm" "$wh" "$table" "$start" "$end" >> "$WINDOWS"
    echo "  window: $start -> $end (UTC)"

    if [ "$interactive" = "yes" ]; then
        echo "  detaching $table (keeps warehouse RUNNING -- never suspend)"
        sf "ALTER WAREHOUSE ${wh} DROP TABLES (IA_BENCH.BENCH.${table});"
    fi
}

: > "$LOG"
[ -f "$WINDOWS" ] || printf 'arm\twarehouse\ttable\tstart_utc\tend_utc\n' > "$WINDOWS"

# ONLY_ARM=C re-runs a single arm using the identical warm/window logic (needed after arm C
# failed due to missing INTERACTIVE TABLE grant).
if [ -n "${ONLY_ARM:-}" ]; then
    echo "### Re-running ONLY arm ${ONLY_ARM} (fresh 1-hour minimum starts on resume) ###"
    case "$ONLY_ARM" in
      C) sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_XS SET AUTO_RESUME = TRUE;"
         sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_XS RESUME;"
         run_arm C FACT_INTERACTIVE IA_BENCH_INTERACTIVE_XS yes
         echo "### Suspending interactive XS ###"
         sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_XS SUSPEND;" ;;
      *) echo "ONLY_ARM=${ONLY_ARM} not supported"; exit 1 ;;
    esac
    echo "=== ARM ${ONLY_ARM} RE-RUN COMPLETE ==="
    cat "$WINDOWS"
    exit 0
fi

echo "### Bringing interactive XS up ONCE (1-hour minimum starts now) ###"
sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_XS SET AUTO_RESUME = TRUE;"
sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_XS RESUME;"

run_arm D  FACT_NONCLUSTERED IA_BENCH_INTERACTIVE_XS yes
run_arm A  FACT_CLUSTERED    IA_BENCH_INTERACTIVE_XS yes
run_arm C  FACT_INTERACTIVE  IA_BENCH_INTERACTIVE_XS yes

echo "### Interactive M up for arm E ###"
sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_M SET AUTO_RESUME = TRUE;"
sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_M RESUME;"
run_arm E  FACT_CLUSTERED    IA_BENCH_INTERACTIVE_M  yes

echo "### Standard baselines (no attachment, no warming) ###"
run_arm B1 FACT_CLUSTERED    IA_BENCH_STD_GEN2_XS    no
run_arm B2 FACT_CLUSTERED    IA_BENCH_STD_MCW_XS     no
run_arm B3 FACT_CLUSTERED    IA_BENCH_ADAPTIVE_WH    no

echo "### Suspending interactive warehouses (all arms done) ###"
sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_XS SUSPEND;"
sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_M SUSPEND;"

echo "=== ALL ARMS COMPLETE ==="
cat "$WINDOWS"
