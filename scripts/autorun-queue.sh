#!/usr/bin/env bash
# autorun-queue.sh — work a queue/ of compiled tasks unattended, across usage windows.
#
# Runs only risk:auto tasks whose deps are done. Gates every task. Parks failures
# on their own branch and continues to the next task. Sleeps through rate limits.
#
# Requires: bash 4+, GNU date, jq, timeout, git, claude.

set -uo pipefail

# ─── portability: Linux / macOS / Windows Git Bash ──────────────────────────
# macOS: re-exec under caffeinate so the Mac never sleeps mid-run
if [[ "$(uname)" == "Darwin" && -z "${_CAFFEINATED:-}" ]] && command -v caffeinate >/dev/null; then
  export _CAFFEINATED=1
  exec caffeinate -i "$0" "$@"
fi
# GNU date needed for reset-time parsing; macOS: brew install coreutils → gdate
DATE_BIN="date"; command -v gdate >/dev/null 2>&1 && DATE_BIN="gdate"
GNU_DATE=1; "$DATE_BIN" -u -d "today 12:00" +%s >/dev/null 2>&1 || GNU_DATE=0
# timeout: coreutils (gtimeout on macOS via brew); degrade to no-timeout if absent
TIMEOUT_BIN=""; for _t in timeout gtimeout; do command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }; done
run_to() { local d="$1"; shift; if [[ -n "$TIMEOUT_BIN" ]]; then "$TIMEOUT_BIN" "$d" "$@"; else "$@"; fi; }
# jq: required for github/gitlab modes; optional in local mode (cost tracking only)
HAS_JQ=1; command -v jq >/dev/null 2>&1 || HAS_JQ=0
# ────────────────────────────────────────────────────────────────────────────

QUEUE_MODE="${QUEUE_MODE:-local}"   # local | github | gitlab
QUEUE_DIR="${QUEUE_DIR:-.agent/queue}"
STATE_DIR="${STATE_DIR:-.agent/run}"
INBOX="${INBOX:-.agent/HUMAN-INBOX.md}"

MODEL="${MODEL:-sonnet}"
MAX_TURNS="${MAX_TURNS:-40}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"          # per task, before parking it
CONSEC_FAIL_LIMIT="${CONSEC_FAIL_LIMIT:-3}" # consecutive parked tasks -> stop (systemic failure)
BUDGET_PER_RUN="${BUDGET_PER_RUN:-3.00}"
BUDGET_TOTAL="${BUDGET_TOTAL:-40.00}"
RUN_TIMEOUT="${RUN_TIMEOUT:-30m}"
DEFAULT_BACKOFF="${DEFAULT_BACKOFF:-300}"
MAX_BACKOFF="${MAX_BACKOFF:-21600}"
RESET_BUFFER="${RESET_BUFFER:-90}"
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Read,Write,Edit,Glob,Grep,Bash}"
DISALLOWED_TOOLS="${DISALLOWED_TOOLS:-Bash(git push:*),Bash(git filter-repo:*),Bash(git reset:*),Bash(git rebase:*),Bash(rm:*),Bash(git rm:*),Bash(supabase:*),WebFetch}"

LOG="$STATE_DIR/queue.log"
COST_FILE="$STATE_DIR/cost_usd"
OUT_JSON="$STATE_DIR/last.json"
OUT_ERR="$STATE_DIR/last.err"

mkdir -p "$STATE_DIR/state"
[[ -f "$COST_FILE" ]] || echo "0" > "$COST_FILE"
[[ -f "$INBOX" ]] || printf '# Human inbox\n\nTasks the agent could not or must not do.\n\n' > "$INBOX"

log() { printf '[%s] %s\n' "$(date -u '+%m-%d %H:%M:%SZ')" "$*" | tee -a "$LOG"; }
trap 'log "interrupted"; exit 130' INT TERM

for b in claude git; do command -v "$b" >/dev/null || { echo "missing: $b" >&2; exit 1; }; done
[[ -z "$TIMEOUT_BIN" ]] && log "⚠ no timeout binary (macOS: brew install coreutils) — stuck agents won't be killed"
(( GNU_DATE )) || log "⚠ no GNU date (macOS: brew install coreutils) — rate-limit sleeps use ${DEFAULT_BACKOFF}s backoff instead of exact reset time"
if (( ! HAS_JQ )); then
  [[ "$QUEUE_MODE" != "local" ]] && { echo "QUEUE_MODE=$QUEUE_MODE requires jq" >&2; exit 1; }
  log "⚠ jq missing — cost tracking disabled (budget cap inactive)"
fi
fallback_local() { # fallback_local <reason>
  log "⚠ QUEUE_MODE=$QUEUE_MODE unavailable: $1"
  if [[ -d "$QUEUE_DIR" ]] && ls "$QUEUE_DIR"/[0-9]*.md >/dev/null 2>&1; then
    log "⚠ FALLING BACK to QUEUE_MODE=local ($QUEUE_DIR/). Issue tracking will NOT be updated this run."
    QUEUE_MODE=local
  else
    echo "QUEUE_MODE=$QUEUE_MODE unavailable ($1) and no local $QUEUE_DIR/ to fall back to." >&2
    echo "Fix: authenticate ('gh auth login' / 'glab auth login'), or re-emit the queue in local mode." >&2
    exit 1
  fi
}

case "$QUEUE_MODE" in
  local)  [[ -d "$QUEUE_DIR" ]] || { echo "no $QUEUE_DIR — run doc-triage first" >&2; exit 1; } ;;
  github) if ! command -v gh >/dev/null; then fallback_local "gh CLI not installed"
          elif ! gh auth status >/dev/null 2>&1; then fallback_local "gh not authenticated"; fi ;;
  gitlab) if ! command -v glab >/dev/null; then fallback_local "glab CLI not installed"
          elif ! glab auth status >/dev/null 2>&1; then fallback_local "glab not authenticated"; fi ;;
  *) echo "bad QUEUE_MODE: $QUEUE_MODE (local|github|gitlab)" >&2; exit 1 ;;
esac

# --------------------------------------------------------------- frontmatter ---
fm() { # fm <file> <key> — value may contain colons
  sed -n '2,/^---$/p' "$1" | grep -m1 "^$2:" | sed "s/^$2: *//; s/ *\$//"
}
status_of() { local s="$STATE_DIR/state/$1"; [[ -f "$s" ]] && cat "$s" || echo pending; }
set_status() { echo "$2" > "$STATE_DIR/state/$1"; }

# ---- task source abstraction: local files vs github vs gitlab issues ----
# fetch_tasks: materialize every candidate task as a file in $STATE_DIR/tasks/
# and echo its path + platform ref. Issue modes cache issue number/iid per id.
fetch_tasks() {
  mkdir -p "$STATE_DIR/tasks"
  case "$QUEUE_MODE" in
    local)
      local f; for f in "$QUEUE_DIR"/[0-9]*.md; do [[ -e "$f" ]] && echo "$f"; done ;;
    github)
      gh issue list --label agent-auto --state open --limit 200 \
        --json number,body -q '.[] | @base64' | while read -r row; do
        local n b p
        n=$(echo "$row" | base64 -d | jq -r .number)
        b=$(echo "$row" | base64 -d | jq -r .body)
        p="$STATE_DIR/tasks/gh-$n.md"; printf '%s\n' "$b" > "$p"
        echo "$(fm "$p" id)" > "$STATE_DIR/tasks/ref-gh-$n" 2>/dev/null || true
        echo "$n" > "$STATE_DIR/tasks/num-$(fm "$p" id)" 2>/dev/null || true
        echo "$p"
      done ;;
    gitlab)
      glab issue list --label agent-auto --output json 2>/dev/null \
        | jq -r '.[] | @base64' | while read -r row; do
        local n b p
        n=$(echo "$row" | base64 -d | jq -r .iid)
        b=$(echo "$row" | base64 -d | jq -r .description)
        p="$STATE_DIR/tasks/gl-$n.md"; printf '%s\n' "$b" > "$p"
        echo "$n" > "$STATE_DIR/tasks/num-$(fm "$p" id)" 2>/dev/null || true
        echo "$p"
      done ;;
  esac
}

issue_num() { cat "$STATE_DIR/tasks/num-$1" 2>/dev/null || true; }

report_done() { # report_done <id> <summary>
  local n; n="$(issue_num "$1")"
  case "$QUEUE_MODE" in
    github) [[ -n "$n" ]] && { gh issue comment "$n" --body "✅ Gate passed. $2" >/dev/null; gh issue close "$n" >/dev/null; } ;;
    gitlab) [[ -n "$n" ]] && { glab issue note "$n" -m "✅ Gate passed. $2" >/dev/null; glab issue close "$n" >/dev/null; } ;;
  esac
}

report_parked() { # report_parked <id> <reason> — inbox entry already written
  local n tail_log; n="$(issue_num "$1")"
  tail_log="$(tail -n 15 "$OUT_ERR" 2>/dev/null)"
  case "$QUEUE_MODE" in
    github) [[ -n "$n" ]] && { gh issue edit "$n" --add-label agent-parked >/dev/null 2>&1
              gh issue comment "$n" --body "⏸ Parked: $2
\\`\\`\\`
$tail_log
\\`\\`\\`" >/dev/null; } ;;
    gitlab) [[ -n "$n" ]] && { glab issue update "$n" --label agent-parked >/dev/null 2>&1
              glab issue note "$n" -m "⏸ Parked: $2
\\`\\`\\`
$tail_log
\\`\\`\\`" >/dev/null; } ;;
  esac
}

deps_met() {
  local deps; deps="$(fm "$1" deps)"
  [[ -z "$deps" ]] && return 0
  local d
  for d in ${deps//,/ }; do
    [[ "$(status_of "${d// /}")" == "done" ]] || return 1
  done
  return 0
}

next_task() {
  local f
  for f in $(fetch_tasks); do
    [[ -e "$f" ]] || continue
    [[ "$(fm "$f" risk)" == "auto" ]] || continue
    [[ "$(status_of "$(fm "$f" id)")" == "pending" ]] || continue
    deps_met "$f" || continue
    echo "$f"; return 0
  done
  return 1
}

park() { # park <file> <id> <reason>
  local base="$4"
  set_status "$2" blocked
  { echo "## $(fm "$1" id) — $(fm "$1" title)"
    echo "- **Reason:** $3"
    echo "- **Task:** \`$1\`"
    if [[ -n "$base" && "$(git rev-parse HEAD)" != "$base" ]]; then
      git branch -f "parked/$2" >/dev/null 2>&1
      git reset --hard "$base" >/dev/null 2>&1
      echo "- **Work preserved on:** \`parked/$2\` (main line reset clean)"
    fi
    echo "- **Log tail:**"
    echo '```'; tail -n 15 "$OUT_ERR" 2>/dev/null; echo '```'
    echo
  } >> "$INBOX"
  log "PARKED $2 — $3"
}

# ------------------------------------------------------------- rate limiting ---
is_rate_limited() {
  grep -qiE "session limit|usage limit|weekly limit|rate.?limit|limit reached|429|resets [0-9]{1,2}:[0-9]{2}" <<<"$1"
}
seconds_until_reset() {
  local stamp target now
  stamp=$(grep -oiE 'resets?[[:space:]]+(at[[:space:]]+)?[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' <<<"$1" \
          | head -n1 | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?$' | tr -d ' ')
  [[ -z "$stamp" ]] && return 1
  # "10am" / "14" → add minutes so date can parse it
  [[ "$stamp" =~ : ]] || stamp="$(sed -E 's/^([0-9]{1,2})/\1:00/' <<<"$stamp")"
  (( GNU_DATE )) || return 1
  target=$("$DATE_BIN" -u -d "today $stamp" +%s 2>/dev/null) || return 1
  now=$("$DATE_BIN" -u +%s); (( target <= now )) && target=$("$DATE_BIN" -u -d "tomorrow $stamp" +%s)
  echo $(( target - now + RESET_BUFFER ))
}
sleep_until() {
  local s="$1" end
  (( s > MAX_BACKOFF )) && s=$MAX_BACKOFF
  end=$(( $(date +%s) + s ))
  if (( GNU_DATE )); then
    log "sleeping ${s}s → $("$DATE_BIN" -u -d "@$end" '+%H:%MZ') / $("$DATE_BIN" -d "@$end" '+%H:%M local')"
  else
    log "sleeping ${s}s"
  fi
  while (( $(date +%s) < end )); do sleep 30; done
}
budget_left() { awk -v s="$(cat "$COST_FILE")" -v c="$BUDGET_TOTAL" 'BEGIN{exit !(s<c)}'; }
record_cost() {
  local c
  if (( HAS_JQ )); then
    c=$(grep '"type":"result"' "$OUT_JSON" 2>/dev/null | tail -n1 | jq -r '.total_cost_usd // .cost_usd // 0' 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    c=$(python3 - "$OUT_JSON" <<'PY' 2>/dev/null
import json,sys
c=0
for line in open(sys.argv[1]):
    try: d=json.loads(line)
    except Exception: continue
    if d.get("type")=="result": c=d.get("total_cost_usd") or d.get("cost_usd") or 0
print(c)
PY
)
  else
    c=0
  fi
  [[ "$c" == "null" || -z "$c" ]] && c=0
  awk -v a="$(cat "$COST_FILE")" -v b="$c" 'BEGIN{printf "%.4f", a+b}' > "$COST_FILE.tmp"
  mv "$COST_FILE.tmp" "$COST_FILE"
  log "cost \$$c | total \$$(cat "$COST_FILE")"
}

# ---------------------------------------------------------------- main loop ----
log "=== queue start | mode=$QUEUE_MODE | model=$MODEL ==="

# Park the non-auto tasks into the inbox once, up front (local mode only;
# issue modes fetch only agent-auto by label).
[[ "$QUEUE_MODE" == "local" ]] && for f in "$QUEUE_DIR"/[0-9]*.md; do
  [[ -e "$f" ]] || continue
  r="$(fm "$f" risk)"; id="$(fm "$f" id)"
  [[ "$r" == "auto" ]] && continue
  [[ "$(status_of "$id")" == "pending" ]] || continue
  set_status "$id" "needs-human"
  printf '## %s — %s\n- **Risk:** %s (not run unattended)\n- **Task:** `%s`\n\n' \
    "$id" "$(fm "$f" title)" "$r" "$f" >> "$INBOX"
done

consec_fails=0
while :; do
  (( consec_fails >= CONSEC_FAIL_LIMIT )) && { log "STOP: $consec_fails consecutive failures — likely systemic; fix and rerun"; break; }
  budget_left || { log "budget cap \$$BUDGET_TOTAL reached"; break; }
  task="$(next_task)" || { log "no eligible tasks left"; break; }

  id="$(fm "$task" id)"; title="$(fm "$task" title)"; gate="$(fm "$task" gate)"
  set_status "$id" running
  base="$(git rev-parse HEAD)"
  log "▶ $id — $title"

  attempt=0
  rl_streak=0
  while (( attempt < MAX_ATTEMPTS )); do
    (( attempt++ ))

    prompt="You are running autonomously. No human will answer questions — never
ask for confirmation, never end by offering to do more. Decide and act.

Your task is defined in: $task
Read it. Do ONLY that task, completely. Verify with its gate: $gate
Commit your work with a descriptive message.

Append to .agent/PROGRESS.md: what you did, files touched, decisions, and anything the
next agent needs. Write for someone with zero memory of this session.

If you cannot proceed without a human decision, or the task requires anything on
its NEVER list, write the blocker to .agent/PROGRESS.md and stop immediately. Do not
improvise around a blocker."

    run_to "$RUN_TIMEOUT" claude -p "$prompt" \
      --model "$MODEL" --output-format stream-json --verbose \
      --allowedTools "$ALLOWED_TOOLS" --disallowedTools "$DISALLOWED_TOOLS" \
      --max-turns "$MAX_TURNS" --max-budget-usd "$BUDGET_PER_RUN" \
      >"$OUT_JSON" 2>"$OUT_ERR"
    rc=$?
    combined="$(cat "$OUT_JSON" "$OUT_ERR" 2>/dev/null)"

    if (( rc != 0 )) && is_rate_limited "$combined"; then
      log "usage limit hit"
      if w=$(seconds_until_reset "$combined"); then
        rl_streak=0
      else
        (( rl_streak++ ))
        w=$(( DEFAULT_BACKOFF * (1 << (rl_streak > 1 ? rl_streak - 1 : 0)) ))
        (( w > MAX_BACKOFF )) && w=$MAX_BACKOFF
        log "reset time unparseable → backoff ${w}s (tentative $rl_streak — s'allonge tant que la limite persiste)"
      fi
      sleep_until "$w"
      (( attempt-- ))          # a rate limit is not a failed attempt
      continue
    fi
    rl_streak=0

    (( rc == 0 )) && record_cost

    if (( rc == 124 )); then
      log "timeout after $RUN_TIMEOUT (attempt $attempt)"; continue
    fi
    if (( rc != 0 )); then
      log "agent exited $rc (attempt $attempt)"; continue
    fi

    log "gate: $gate"
    if run_to 15m bash -c "$gate" >>"$LOG" 2>&1; then
      set_status "$id" done
      report_done "$id" "Committed on $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)."
      log "✔ $id passed gate"
      break
    fi
    log "✘ gate failed (attempt $attempt/$MAX_ATTEMPTS)"
  done

  if [[ "$(status_of "$id")" == "done" ]]; then
    consec_fails=0
  else
    park "$task" "$id" "failed gate or agent after $MAX_ATTEMPTS attempts" "$base"
    report_parked "$id" "failed gate or agent after $MAX_ATTEMPTS attempts"
    (( consec_fails++ ))
  fi
done

log "=== finished | spend \$$(cat "$COST_FILE") ==="
printf 'done: %s | blocked: %s | needs-human: %s\n' \
  "$(grep -lx done "$STATE_DIR"/state/* 2>/dev/null | wc -l)" \
  "$(grep -lx blocked "$STATE_DIR"/state/* 2>/dev/null | wc -l)" \
  "$(grep -lx needs-human "$STATE_DIR"/state/* 2>/dev/null | wc -l)" | tee -a "$LOG"
