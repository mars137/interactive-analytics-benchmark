#!/usr/bin/env bash
# WI-22 arm orchestrator: attach -> warm -> run -> detach, per arm, unattended.
#
# WHY THIS IS SCRIPTED
# Each interactive arm needs ITS OWN variant attached, because all three variants are ~400 GB
# and the interactive XS data cache cannot hold them together -- co-attaching would let the
# variants evict each other and silently contaminate arms.
#
# Detach/attach costs warming time but NOT a new billing period, because the warehouse is
# never suspended. Suspending would both reset the caches and start a fresh 1-hour minimum.
#
# Arm order: D first (pruning cliff, nothing to bias), then A (headline), then C (interactive
# table, isolated per the docs' no-interleaving rule), then E on interactive M, then the three
# standard baselines last.
#
# Records a start/end timestamp per arm to /tmp/wi22_arm_windows.tsv so extraction can
# correlate by warehouse + time window (NOT by test_id -- FlakeBench writes two TEST_RESULTS
# rows per run and the API's test_id is not the one in the query tag).

set -uo pipefail

# snow CLI prefers env vars over connections.toml; a stale empty SNOWFLAKE_PASSWORD from
# sourcing FlakeBench's .env makes every call fail with "Password is empty".
unset SNOWFLAKE_PASSWORD SNOWFLAKE_USER SNOWFLAKE_ACCOUNT SNOWFLAKE_ROLE \
      SNOWFLAKE_WAREHOUSE SNOWFLAKE_DATABASE SNOWFLAKE_SCHEMA \
      SNOWFLAKE_PRIVATE_KEY_PATH SNOWFLAKE_PRIVATE_KEY_PASSPHRASE

CONN=demo_atahir
DUR=${DUR:-180}
WINDOWS=/tmp/wi22_arm_windows.tsv
LOG=/tmp/wi22_orchestrate.log
MAX_WARM_SECS=${MAX_WARM_SECS:-1500}

# Authenticate as the IA_BENCH_SVC service user with its KEY PAIR rather than the
# demo_atahir connection.
#
# Why: the demo_atahir connection's password is supplied by an injected env var
# (SNOWFLAKE_CONNECTIONS_DEMO_ATAHIR_PASSWORD) that BACKGROUND shells do not inherit -- that
# is what made an earlier background harvest fail 22/22 with "Password is empty". A key pair
# is a file on disk, so it works in any shell, which this long unattended run requires.
# FLAKEBENCH_ROLE has been granted OPERATE on the benchmark warehouses so it can
# resume/suspend, and MANAGE ATTACHED TABLES so it can attach/detach.
SF_ARGS=(--temporary-connection
         --account SFSENORTHAMERICA-DEMO_ATAHIR
         --user IA_BENCH_SVC
         --private-key-file "$HOME/.snowflake/keys/ia_bench_svc.p8"
         --authenticator SNOWFLAKE_JWT
         --role FLAKEBENCH_ROLE
         --warehouse COMPUTE_WH)

sf() { snow sql "${SF_ARGS[@]}" -q "$1" >>"$LOG" 2>&1; }

# Extract a single scalar from `snow sql --format json`.
# CRITICAL: for a MULTI-statement query, snow returns a LIST OF RESULT SETS
# (e.g. [[{status..}],[{status..}],[{"COUNT(*)":9772}],[{status..}],[{"PCT":0.0}]]).
# Taking d[0] would return "Statement executed successfully." instead of the value we want,
# which would make the warm gate never plateau and burn the full max-wait on every arm.
# So: walk to the LAST result set, then its first row, then its first column.
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
    # Returns avg pct_from_cache (0-1) for a representative query on $1 (table), via
    # GET_QUERY_OPERATOR_STATS, or -1 if stats were unavailable.
    # Result cache MUST be off or the probe returns no TableScan at all.
    # GET_QUERY_OPERATOR_STATS intermittently returns no rows for a just-finished query, so
    # retry a couple of times before reporting unknown.
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
    # FIXED-DURATION, QUERY-DRIVEN WARM UP (fallback -- see note below).
    #
    # WHY NOT A MEASURED GATE: GET_QUERY_OPERATOR_STATS returns 0 rows for
    # IA_BENCH_SVC / FLAKEBENCH_ROLE even on queries that role just ran, and granting both
    # OPERATE and MONITOR on the warehouse did NOT change that. Earlier probes only worked
    # because they ran as ACCOUNTADMIN, and a long unattended background run cannot use the
    # ACCOUNTADMIN connection (background shells do not inherit its injected password).
    #
    # So instead of gating on a measurement we cannot obtain live, we warm for a fixed period
    # while actively issuing representative queries, then report the ACHIEVED cache percentage
    # retrospectively from ACCOUNT_USAGE.PERCENTAGE_SCANNED_FROM_CACHE (available after its
    # ~45 min lag). Weaker than a live gate, and the post must say so plainly -- but the warm
    # state per arm is still measured and reported, just after the fact rather than before.
    #
    # Issuing queries during warm-up is not merely filler: per the docs, cache warming is
    # prioritised (1) micropartitions needed by user queries, (2) newly ingested partitions,
    # (3) remaining partitions of attached tables. Driving real queries pulls the working set
    # in first, which is exactly the set the arm will measure.
    local table="$1" wh="$2" waited=0
    echo "    warming ${table} on ${wh} for ${MAX_WARM_SECS}s (query-driven, fixed duration)"
    while [ "$waited" -lt "$MAX_WARM_SECS" ]; do
        # Rotate accounts so warming touches a spread of micropartitions rather than one slice.
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

# ONLY_ARM=C re-runs a single arm using the IDENTICAL warm-up and window logic, rather than a
# divergent one-off script. Needed because arm C originally failed in 33s: FLAKEBENCH_ROLE had
# no SELECT on FACT_INTERACTIVE, since INTERACTIVE TABLES are a SEPARATE grant object class and
# `GRANT SELECT ON ALL/FUTURE TABLES` silently does not cover them.
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
sf "ALTER WAREHOUSE IA_BENCH_INTERACTIVE_XS SET AUTO_RESUME = TRUE;"  # already resumed; idempotent
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
