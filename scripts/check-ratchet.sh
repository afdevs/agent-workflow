#!/usr/bin/env bash
# check-ratchet.sh — enforce monotonic improvement on a metric that starts dirty.
#
# You cannot gate on "tsc is clean" when there are 541 pre-existing errors.
# You CAN gate on "the number never goes up". That is the ratchet: it lets an
# agent work inside a broken baseline without ever making it worse.
#
# Usage:  ./check-ratchet.sh          -> pass/fail vs baseline, tightens on improvement
#         ./check-ratchet.sh --init   -> record the current count as baseline

set -uo pipefail
BASELINE_FILE="${BASELINE_FILE:-.autorun/tsc-baseline}"

count_errors() { npx tsc --noEmit 2>&1 | grep -cE "error TS[0-9]+" || true; }

mkdir -p "$(dirname "$BASELINE_FILE")"
current=$(count_errors)

if [[ "${1:-}" == "--init" ]]; then
  echo "$current" > "$BASELINE_FILE"
  echo "baseline recorded: $current tsc errors"; exit 0
fi

[[ -f "$BASELINE_FILE" ]] || { echo "no baseline — run --init first" >&2; exit 2; }
baseline=$(cat "$BASELINE_FILE")

if (( current > baseline )); then
  echo "RATCHET BROKEN: $baseline -> $current (+$((current - baseline))). Revert or fix." >&2
  exit 1
fi

if (( current < baseline )); then
  echo "$current" > "$BASELINE_FILE"
  echo "ratchet tightened: $baseline -> $current (-$((baseline - current)))"
else
  echo "ratchet held at $current"
fi
exit 0
