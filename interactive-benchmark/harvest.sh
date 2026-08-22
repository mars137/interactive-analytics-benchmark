#!/usr/bin/env bash
# WI-22 harvest runner.
#
# DATA_AGENT_RUN requires CONSTANT arguments, so it cannot be driven from a table column
# (verified: "argument 1 ... needs to be constant"). Each question therefore gets its own
# statement with the text inlined as a literal, which also isolates failures: one bad
# question does not lose the whole harvest.
#
# Responses are stored as VARIANT server-side because client output truncates at 4 KB.

set -uo pipefail

# The snow CLI prefers env vars over connections.toml; a stale empty SNOWFLAKE_PASSWORD
# (left behind by sourcing FlakeBench's .env) makes it fail with "Password is empty".
unset SNOWFLAKE_PASSWORD SNOWFLAKE_USER SNOWFLAKE_ACCOUNT SNOWFLAKE_ROLE \
      SNOWFLAKE_WAREHOUSE SNOWFLAKE_DATABASE SNOWFLAKE_SCHEMA \
      SNOWFLAKE_PRIVATE_KEY_PATH SNOWFLAKE_PRIVATE_KEY_PASSPHRASE

QFILE="${1:-/tmp/wi22_questions.tsv}"
CONN="${CONN:-demo_atahir}"
LOG="/tmp/wi22_harvest.log"
: > "$LOG"

ok=0; fail=0

while IFS=$'\t' read -r qid question; do
    [ -z "${qid:-}" ] && continue

    # Escape single quotes for the SQL literal.
    esc_q=${question//\'/\'\'}

    sql="INSERT INTO IA_BENCH.BENCH.AGENT_HARVEST (q_id, question, resp)
SELECT ${qid},
       '${esc_q}',
       PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
           'IA_BENCH.BENCH.ENGAGEMENT_AGENT',
           '{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"${esc_q}\"}]}]}'
       ));"

    start=$(date +%s)
    if snow sql -c "$CONN" -q "$sql" >>"$LOG" 2>&1; then
        dur=$(( $(date +%s) - start ))
        printf 'q%-3s ok    %3ss\n' "$qid" "$dur"
        ok=$((ok+1))
    else
        dur=$(( $(date +%s) - start ))
        printf 'q%-3s FAIL  %3ss\n' "$qid" "$dur"
        fail=$((fail+1))
    fi
done < "$QFILE"

echo "=== harvest done: ok=$ok fail=$fail (log: $LOG) ==="
