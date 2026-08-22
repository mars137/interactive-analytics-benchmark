#!/usr/bin/env bash
# WI-22: run controls and arm F in ONE interactive resume (avoids extra 1-hour billing minimum).
# Does NOT suspend at end -- arm F runs next in foreground.
set -uo pipefail
cd "$(dirname "$0")/.."

MAX_WARM_SECS="${MAX_WARM_SECS:-1200}"
REPS="${REPS:-60}"
INT_WH=IA_BENCH_INTERACTIVE_XS
STD_WH=IA_BENCH_STD_GEN2_XS
TABLE=FACT_CLUSTERED

SF_ARGS=(--temporary-connection
         --account SFSENORTHAMERICA-DEMO_ATAHIR
         --user IA_BENCH_SVC
         --private-key-file "$HOME/.snowflake/keys/ia_bench_svc.p8"
         --authenticator SNOWFLAKE_JWT
         --role FLAKEBENCH_ROLE
         --warehouse COMPUTE_WH)

sf() {
    unset SNOWFLAKE_PASSWORD SNOWFLAKE_USER SNOWFLAKE_ACCOUNT SNOWFLAKE_ROLE \
          SNOWFLAKE_WAREHOUSE SNOWFLAKE_DATABASE SNOWFLAKE_SCHEMA \
          SNOWFLAKE_PRIVATE_KEY_PATH SNOWFLAKE_PRIVATE_KEY_PASSPHRASE
    snow sql "${SF_ARGS[@]}" -q "$1" 2>&1 | tail -3
}

echo "### resuming ${INT_WH} (fresh 1-hour minimum) and attaching ${TABLE} ###"
sf "ALTER WAREHOUSE ${INT_WH} SET AUTO_RESUME = TRUE;"
sf "ALTER WAREHOUSE ${INT_WH} RESUME;"
sf "ALTER WAREHOUSE ${INT_WH} ADD TABLES (IA_BENCH.BENCH.${TABLE});"

echo "### warming ${TABLE} for ${MAX_WARM_SECS}s (query-driven, fixed duration) ###"
waited=0
while [ "$waited" -lt "$MAX_WARM_SECS" ]; do
    for acct in 1 250 50000 120000 190000; do
        sf "ALTER SESSION SET USE_CACHED_RESULT = FALSE;
            USE WAREHOUSE ${INT_WH};
            SELECT COUNT(*) c, COUNT(DISTINCT contact_id) dc
            FROM IA_BENCH.BENCH.${TABLE}
            WHERE account_id = ${acct} AND event_date >= '2026-07-24';" >/dev/null
    done
    waited=$((waited+120)); printf '  warmed %ss / %ss\n' "$waited" "$MAX_WARM_SECS"
done

echo "### controls on INTERACTIVE (${INT_WH}) ###"
python3 interactive-benchmark/run_controls.py --warehouse "$INT_WH" --reps "$REPS" \
        --tag-suffix _int 2>&1 | grep -vi "userwarning\|from pandas"

echo "### controls on STANDARD (${STD_WH}) ###"
python3 interactive-benchmark/run_controls.py --warehouse "$STD_WH" --reps "$REPS" \
        --tag-suffix _std 2>&1 | grep -vi "userwarning\|from pandas"

echo "### CONTROLS DONE -- ${INT_WH} left RUNNING for arm F; suspend after arm F ###"
