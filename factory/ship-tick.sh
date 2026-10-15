#!/usr/bin/env bash
# The factory tick, run by cron every 5 minutes:
#   find agent:ready tickets across the owner's private repos, and for each
#   set-up repo with nothing in flight launch one `/ship-bg` run on its oldest
#   ready ticket, behind the usage gate.
#
#   ship-tick.sh            the tick
#   ship-tick.sh --dry-run  run every check, launch nothing, record nothing
#
# Steps are functions called in order from main(), so later pieces (record,
# stale runs, cleanup, dashboard) slot in between them.

source "$(dirname "$0")/lib.sh"
require_tools claude gh node jq flock curl

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR"
LAUNCHES="$STATE_DIR/launches.json"
LAST_TICK="$STATE_DIR/last-tick.json"
GATE_FILE="$STATE_DIR/gate.json"
GATE_CLOSED_UNTIL="$STATE_DIR/gate-closed-until"
TICK_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LAUNCH_GRACE_SECS=600

# Filled in by the steps below.
OWNER_LOGIN=""
READY="[]"          # gh search result, minus EXCLUDE_REPOS
AGENTS="[]"         # claude agents --json --all
GATE=""             # usage.jq output, once checked
CANDIDATES="[]"     # [{repo, full, issue, title, model, clone}]
LAUNCHED=0
FAILED_REPOS=0

# ---------------------------------------------------------------- helpers

say() {
  # Human-readable progress. In --dry-run it is the report.
  echo "$*" >&2
}

save_last_tick() {
  $DRY_RUN && return 0
  jq -nc --arg ts "$TICK_TS" --arg outcome "$1" '{ts: $ts, outcome: $outcome}' | write_atomic "$LAST_TICK"
}

on_error() {
  local cmd=$1 code=$2
  local msg="error: '$cmd' failed (exit $code)"
  # A failure inside a command substitution fires this trap once per nesting
  # level; the innermost one has already reported, so the others just exit.
  if [[ -e "$STATE_DIR/alerted/error:$TICK_TS" ]]; then
    exit 1
  fi
  log "$msg"
  if ! $DRY_RUN; then
    save_last_tick "$msg" || true
    alert "error:$TICK_TS" "ship-tick failed" "$msg" || true
  fi
  exit 1
}
# -E so the trap also fires inside functions and command substitutions.
set -E
trap 'on_error "$BASH_COMMAND" "$?"' ERR

take_lock() {
  exec 9>"$STATE_DIR/lock"
  if ! flock -n 9; then
    log "another tick holds the lock"
    exit 0
  fi
}

load_agents() {
  AGENTS=$(claude agents --json --all 2>/dev/null || echo '[]')
  [[ -z "$AGENTS" ]] && AGENTS='[]'
  return 0
}

launches() {
  if [[ -f "$LAUNCHES" ]]; then cat "$LAUNCHES"; else echo '[]'; fi
}

open_launches() {
  launches | jq -c '[.[] | select(.closed_at == null)]'
}

# -------------------------------------------------------------- find work

find_work() {
  OWNER_LOGIN=$(owner)
  local raw excluded
  raw=$(gh search issues --owner "$OWNER_LOGIN" --label agent:ready --state open \
          --visibility private --archived=false \
          --json repository,number,title,labels,createdAt --limit 200)
  excluded=$(printf '%s\n' $EXCLUDE_REPOS | jq -R . | jq -sc .)
  READY=$(jq -c --argjson ex "$excluded" '[.[] | select(.repository.name as $r | $ex | index($r) | not)]' <<<"$raw")
}

# True when launches.json has a launch in <repo> whose session is still
# working or blocked, or that started under LAUNCH_GRACE_SECS ago.
launched_already() {
  local repo=$1 now
  now=$(date -u +%s)
  open_launches | jq -e --arg repo "$repo" --argjson now "$now" --argjson grace "$LAUNCH_GRACE_SECS" \
    --argjson agents "$AGENTS" '
      map(select(.repo == $repo))
      | map(
          (.session_id as $id | $agents | map(select(.id == $id and (.state == "working" or .state == "blocked"))) | length > 0)
          or ((.launched_at | sub("\\.[0-9]+"; "") | fromdateiso8601) > ($now - $grace))
        )
      | any' >/dev/null
}

# True when the repo has an open ticket on agent:working, agent:review or
# agent:done. Asked of the repo directly: search results trail label changes.
in_flight() {
  local full=$1 hits
  hits=$(gh issue list --repo "$full" --state open \
           --search 'label:"agent:working","agent:review","agent:done"' \
           --json number --limit 50 | jq -r '.[].number' | tr '\n' ' ')
  IN_FLIGHT_TICKETS=$hits
  [[ -n "$hits" ]]
}

model_for_labels() {
  # stdin: the issue's labels as a JSON array of {name}
  jq -r --arg default "$DEFAULT_MODEL" '
    map(.name) as $l
    | if ($l | index("model:fable")) then "fable"
      elif ($l | index("model:opus")) then "opus"
      else $default end'
}

# The ticket is still open, still agent:ready, and not a draft.
still_ready() {
  local full=$1 issue=$2
  gh issue view "$issue" --repo "$full" --json state,labels \
    | jq -e '.state == "OPEN"
             and ((.labels | map(.name) | index("agent:ready")) != null)
             and ((.labels | map(.name) | index("draft")) == null)' >/dev/null
}

pick_candidates() {
  local repos repo full clone count ticket issue title model
  repos=$(jq -r '[.[].repository.name] | unique | .[]' <<<"$READY")
  for repo in $repos; do
    full="$OWNER_LOGIN/$repo"
    clone="$REPOS_DIR/$repo"
    count=$(jq --arg r "$repo" '[.[] | select(.repository.name == $r)] | length' <<<"$READY")
    say "$full: $count ready"

    if [[ ! -e "$STATE_DIR/setup/$repo" ]] || ! repo_is_trusted "$clone"; then
      say "  needs setup: run factory/setup-repo.sh $full"
      $DRY_RUN || alert "needs_setup:$full" "Repo needs setup: $full" \
        "Ready work in $full, but setup-repo.sh has not marked it set up (or the clone at $clone is not trusted)." \
        "https://github.com/$full/issues?q=is%3Aopen+label%3Aagent%3Aready"
      continue
    fi

    if in_flight "$full"; then
      say "  in flight: #${IN_FLIGHT_TICKETS% }"
      continue
    fi

    if launched_already "$repo"; then
      say "  launched already: $(open_launches | jq -r --arg r "$repo" '[.[] | select(.repo == $r)] | last | "#\(.issue) \(.name) at \(.launched_at)"')"
      continue
    fi

    ticket=$(jq -c --arg r "$repo" '[.[] | select(.repository.name == $r)] | sort_by(.createdAt) | first' <<<"$READY")
    issue=$(jq -r '.number' <<<"$ticket")
    title=$(jq -r '.title' <<<"$ticket")
    model=$(jq -c '.labels' <<<"$ticket" | model_for_labels)

    if ! still_ready "$full" "$issue"; then
      say "  #$issue no longer ready, skipped"
      continue
    fi

    say "  would launch #$issue ($title) on $model"
    CANDIDATES=$(jq -c --arg repo "$repo" --arg full "$full" --argjson issue "$issue" \
      --arg title "$title" --arg model "$model" --arg clone "$clone" \
      '. + [{repo: $repo, full: $full, issue: $issue, title: $title, model: $model, clone: $clone}]' <<<"$CANDIDATES")
  done
}

# ------------------------------------------------------------- usage gate

# Sets GATE. Writes gate.json and gate-closed-until unless --dry-run.
check_gate() {
  local until now
  if [[ -f "$GATE_CLOSED_UNTIL" ]]; then
    until=$(cat "$GATE_CLOSED_UNTIL")
    now=$(date -u +%s)
    if [[ -n "$until" ]] && (( $(date -u -d "$until" +%s 2>/dev/null || echo 0) > now )); then
      say "gate: closed until $until (not re-checked)"
      GATE=$(jq -nc --arg u "$until" '{open: false, resets_at: $u, cached: true}')
      return 0
    fi
  fi

  local raw
  raw=$(timeout 120 claude -p "/usage" --output-format stream-json --verbose 2>/dev/null || true)
  GATE=$(jq -s --arg session_max "$SESSION_MAX_PCT" --arg weekly_max "$WEEKLY_MAX_PCT" \
           -f "$FACTORY_DIR/usage.jq" <<<"$raw" 2>/dev/null \
         || jq -nc '{open: false, error: "unparseable /usage output"}')
  GATE=$(jq -c --arg ts "$TICK_TS" '. + {checked_at: $ts}' <<<"$GATE")

  local open err resets
  open=$(jq -r '.open' <<<"$GATE")
  err=$(jq -r '.error // empty' <<<"$GATE")
  resets=$(jq -r '.resets_at // empty' <<<"$GATE")
  if [[ "$open" == "true" ]]; then
    say "gate: open (session $(jq -r .session_pct <<<"$GATE")%, weekly $(jq -r .weekly_pct <<<"$GATE")%)"
  elif [[ -n "$err" ]]; then
    say "gate: closed ($err)"
  else
    say "gate: closed (session $(jq -r .session_pct <<<"$GATE")%, weekly $(jq -r .weekly_pct <<<"$GATE")%), resets $resets"
  fi

  $DRY_RUN && return 0
  write_atomic "$GATE_FILE" <<<"$GATE"
  if [[ "$open" != "true" && -n "$resets" ]]; then
    write_atomic "$GATE_CLOSED_UNTIL" <<<"$resets"
  else
    rm -f "$GATE_CLOSED_UNTIL"
  fi
}

gate_open() {
  [[ "$(jq -r '.open' <<<"$GATE")" == "true" ]]
}

model_over_weekly() {
  local model=$1
  jq -e --arg m "$model" '(.scoped_over // []) | index($m) != null' <<<"$GATE" >/dev/null
}

# ----------------------------------------------------------------- launch

slug_for() {
  printf '%s' "$1" | cut -d' ' -f1,2 | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' | cut -c1-24
}

session_id_for_name() {
  # Fallback when the `backgrounded · <id> · <name>` line was not seen.
  local name=$1 clone=$2
  claude agents --json --all 2>/dev/null \
    | jq -r --arg n "$name" --arg c "$clone" \
        '[.[] | select(.kind == "background" and .name == $n and (.cwd == $c or (.cwd | startswith($c + "/"))))]
         | sort_by(.startedAt) | last | .id // empty'
}

launch_one() {
  local repo=$1 full=$2 issue=$3 title=$4 model=$5 clone=$6
  local slug name out id
  slug=$(slug_for "$title")
  name="ship-${issue}${slug:+-$slug}"

  if ! out=$(cd "$clone" && claude --bg --name "$name" --model "$model" \
      --permission-mode bypassPermissions --remote-control "$name" "/ship-bg $issue" 2>&1); then
    log "error: launch of $full#$issue refused: ${out//$'\n'/ | }"
    alert "error:$TICK_TS:$full:$issue" "ship-tick: launch refused" "$full#$issue: ${out:0:400}" \
      "https://github.com/$full/issues/$issue"
    FAILED_REPOS=$((FAILED_REPOS + 1))
    return 0
  fi
  id=$(awk -F' · ' '/^backgrounded · /{print $2; exit}' <<<"$out")
  [[ -z "$id" ]] && id=$(session_id_for_name "$name" "$clone")
  if [[ -z "$id" ]]; then
    log "error: launch of $full#$issue printed no session id: ${out//$'\n'/ | }"
    alert "error:$TICK_TS:$full:$issue" "ship-tick: launch without id" "$full#$issue: ${out:0:400}" \
      "https://github.com/$full/issues/$issue"
    FAILED_REPOS=$((FAILED_REPOS + 1))
    return 0
  fi

  log "launched $full#$issue as $name ($id) on $model"
  launches | jq -c --arg repo "$repo" --arg full "$full" --argjson issue "$issue" --arg title "$title" \
      --arg name "$name" --arg model "$model" --arg id "$id" --arg ts "$TICK_TS" \
      '. + [{repo: $repo, full: $full, issue: $issue, title: $title, name: $name, model: $model,
             session_id: $id, launched_at: $ts, closed_at: null}]' \
    | write_atomic "$LAUNCHES"
  LAUNCHED=$((LAUNCHED + 1))
}

launch_candidates() {
  local n i c
  n=$(jq 'length' <<<"$CANDIDATES")
  for ((i = 0; i < n; i++)); do
    c=$(jq -c ".[$i]" <<<"$CANDIDATES")
    local repo full issue title model clone
    repo=$(jq -r .repo <<<"$c"); full=$(jq -r .full <<<"$c"); issue=$(jq -r .issue <<<"$c")
    title=$(jq -r .title <<<"$c"); model=$(jq -r .model <<<"$c"); clone=$(jq -r .clone <<<"$c")
    if model_over_weekly "$model"; then
      say "$full: #$issue skipped, weekly limit for $model is at or above $WEEKLY_MAX_PCT%"
      log "skipped $full#$issue: weekly limit for $model reached"
      continue
    fi
    if $DRY_RUN; then
      say "$full: dry run, would launch #$issue on $model"
      continue
    fi
    launch_one "$repo" "$full" "$issue" "$title" "$model" "$clone"
  done
}

# ------------------------------------------------------------------- main

main() {
  take_lock
  find_work
  load_agents

  local ready_count open_count
  ready_count=$(jq 'length' <<<"$READY")
  open_count=$(open_launches | jq 'length')
  if (( ready_count == 0 && open_count == 0 )); then
    say "nothing ready"
    save_last_tick idle
    return 0
  fi

  pick_candidates
  if [[ "$(jq 'length' <<<"$CANDIDATES")" == "0" ]]; then
    save_last_tick idle
    return 0
  fi

  check_gate
  if ! gate_open; then
    save_last_tick "gate closed"
    return 0
  fi

  launch_candidates
  if (( FAILED_REPOS > 0 )); then
    save_last_tick "error: $FAILED_REPOS launch(es) failed, $LAUNCHED launched"
    return 1
  fi
  if $DRY_RUN; then
    say "dry run: nothing launched, nothing recorded"
  elif (( LAUNCHED > 0 )); then
    save_last_tick "launched $LAUNCHED"
  else
    save_last_tick idle
  fi
}

main
