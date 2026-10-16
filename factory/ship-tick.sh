#!/usr/bin/env bash
# The factory tick, run by cron every 5 minutes:
#   find agent:ready tickets across the owner's private repos, and for each
#   set-up repo with nothing in flight launch one `/ship-bg` run on its oldest
#   ready ticket, behind the usage gate.
#
#   ship-tick.sh            the tick
#   ship-tick.sh --dry-run  run every check, launch nothing, record nothing
#   ship-tick.sh --cleanup  the daily mode: worktrees, old events, closed records
#
# Steps are functions called in order from main(): record, stale runs, find
# work, usage gate, launch, last tick + dashboard.

source "$(dirname "$0")/lib.sh"
require_tools claude gh node jq flock curl

DRY_RUN=false
CLEANUP=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --cleanup) CLEANUP=true ;;
    *) echo "usage: $0 [--dry-run] [--cleanup]" >&2; exit 1 ;;
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

# Every tick ends here, idle ones too, so the dashboard keeps its heartbeat.
save_last_tick() {
  $DRY_RUN && return 0
  jq -nc --arg ts "$TICK_TS" --arg outcome "$1" '{ts: $ts, outcome: $outcome}' | write_atomic "$LAST_TICK"
  render_dashboard
}

# A missing or unwritable WWW_DIR is logged and never fails the tick.
render_dashboard() {
  local err
  if [[ ! -d "$WWW_DIR" || ! -w "$WWW_DIR" ]]; then
    log "dashboard: $WWW_DIR is missing or not writable, page not rendered (see install.sh for the sudo steps)"
    return 0
  fi
  if ! err=$(node "$FACTORY_DIR/render.mjs" "$STATE_DIR" "$WWW_DIR/index.html" 2>&1); then
    log "dashboard: render failed: ${err//$'\n'/ | }"
  fi
  return 0
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
    event error "reason=$msg" || true
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
  AGENTS=$(agents_json)
}

launches() {
  launches_json
}

open_launches() {
  launches | jq -c '[.[] | select(.closed_at == null)]'
}

# event <type> <key=value>... : append one event (not in --dry-run). Values
# are strings; numbers and objects go through event_json.
event() {
  $DRY_RUN && return 0
  local type=$1; shift
  local json
  json=$(jq -nc --arg ts "$TICK_TS" --arg type "$type" '{ts: $ts, type: $type}')
  local kv
  for kv in "$@"; do
    json=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" \
      '. + {($k): (if $k == "issue" then ($v | tonumber? // $v) else $v end)}' <<<"$json")
  done
  append_event "$json"
}

# ----------------------------------------------------------------- record

SNAPSHOT="$STATE_DIR/snapshot.json"
RECORD_EVENTS=0
IN_FLIGHT_COUNT=0
ISSUES="[]"
SESSIONS="{}"

# Step 2: compare GitHub's in-flight tickets with the last snapshot, append
# one event per change (record.mjs decides), alert on failed and held.
record_step() {
  local snapshot issues prs lookups live repos repo key n full look pr_json
  if [[ -f "$SNAPSHOT" ]]; then snapshot=$(cat "$SNAPSHOT"); else snapshot='{}'; fi
  # One search per label: gh search ANDs repeated --label flags.
  local label found
  issues='[]'
  for label in agent:working agent:review agent:done agent:failed; do
    found=$(gh search issues --owner "$OWNER_LOGIN" --visibility private --archived=false --state open \
              --label "$label" --json repository,number,title,labels,url --limit 200)
    issues=$(jq -c --argjson f "$found" \
      '. + $f | unique_by("\(.repository.nameWithOwner)#\(.number)")' <<<"$issues")
  done
  IN_FLIGHT_COUNT=$(jq 'length' <<<"$issues")

  # Open PRs per repo that has an in-flight ticket, asked of the repo
  # directly: search has no headRefName and trails changes.
  prs='{}'
  repos=$(jq -r '[.[].repository.nameWithOwner] | unique | .[]' <<<"$issues")
  for full in $repos; do
    pr_json=$(gh pr list --repo "$full" --state open --json number,title,body,url,headRefName --limit 50)
    prs=$(jq -c --arg r "$full" --argjson p "$pr_json" '. + {($r): $p}' <<<"$prs")
  done

  # Lookups: snapshot keys that left the search; failed tickets' last
  # comment; held candidates' PR comment.
  lookups='{}'
  for key in $(jq -r --argjson cur "$issues" \
      '($cur | map("\(.repository.nameWithOwner)#\(.number)")) as $seen
       | keys[] | select(. as $k | $seen | index($k) | not)' <<<"$snapshot"); do
    full=${key%#*}; n=${key#*#}
    look=$(gh issue view "$n" --repo "$full" --json state,stateReason,labels,closedByPullRequestsReferences 2>/dev/null || echo '')
    [[ -n "$look" ]] && lookups=$(jq -c --arg k "$key" --argjson v "$look" '. + {($k): $v}' <<<"$lookups")
  done
  for key in $(jq -r --argjson snap "$snapshot" \
      '.[] | select(.labels | map(.name) | index("agent:failed"))
       | "\(.repository.nameWithOwner)#\(.number)" | select(($snap[.].failed // false) | not)' <<<"$issues"); do
    full=${key%#*}; n=${key#*#}
    look=$(gh issue view "$n" --repo "$full" --json comments -q '.comments[-1].body // ""' 2>/dev/null || echo '')
    lookups=$(jq -c --arg k "$key" --arg v "$look" '.[$k] = ((.[$k] // {}) + {last_comment: $v})' <<<"$lookups")
  done

  # Sessions for every in-flight ticket and every open launch:
  # SESSIONS = {key: {session, live}}; live = the keys with a live session.
  local s is_live
  SESSIONS='{}'
  for key in $(jq -r '.[] | "\(.repository.nameWithOwner)#\(.number)"' <<<"$issues"; open_launches | jq -r '.[] | "\(.full)#\(.issue)"'); do
    full=${key%#*}; n=${key#*#}
    s=$(ticket_session "$full" "$n")
    is_live=false
    session_is_live "$s" && is_live=true
    SESSIONS=$(jq -c --arg k "$key" --argjson s "${s:-null}" --argjson l "$is_live" '. + {($k): {session: $s, live: $l}}' <<<"$SESSIONS")
  done
  live=$(jq -c '[to_entries[] | select(.value.live) | .key]' <<<"$SESSIONS")
  ISSUES=$issues
  for key in $(jq -r --argjson snap "$snapshot" --argjson live "$live" \
      '.[] | select(.labels | map(.name) | index("agent:done"))
       | "\(.repository.nameWithOwner)#\(.number)"
       | select((($snap[.].held // false) | not) and (($live | index(.)) == null))' <<<"$issues"); do
    full=${key%#*}; n=${key#*#}
    pr=$(jq -r --arg r "$full" --argjson n "$n" --argjson snap "$snapshot" --arg k "$key" \
           '($snap[$k].pr.number // empty)' <<<"$prs")
    if [[ -z "$pr" ]]; then
      pr=$(node -e '
        import("'"$FACTORY_DIR"'/record.mjs").then(m => {
          const prs = JSON.parse(process.argv[1]); const p = m.prFor(prs, process.argv[2]);
          if (p) process.stdout.write(String(p.number));
        })' "$(jq -c --arg r "$full" '.[$r] // []' <<<"$prs")" "$n")
    fi
    [[ -z "$pr" ]] && continue
    look=$(gh pr view "$pr" --repo "$full" --json comments \
             -q '[.comments[].body | select(test("gate"; "i"))] | last // ""' 2>/dev/null || echo '')
    [[ -z "$look" ]] && look=$(gh pr view "$pr" --repo "$full" --json comments -q '.comments[-1].body // ""' 2>/dev/null || echo '')
    lookups=$(jq -c --arg k "$key" --arg v "$look" '.[$k] = ((.[$k] // {}) + {held_reason: $v})' <<<"$lookups")
  done

  local out events new_snapshot
  out=$(jq -nc --arg now "$TICK_TS" --argjson snapshot "$snapshot" --argjson issues "$issues" \
          --argjson prs "$prs" --argjson lookups "$lookups" --argjson launches "$(launches)" --argjson live "$live" \
          '{now: $now, snapshot: $snapshot, issues: $issues, prs: $prs, lookups: $lookups, launches: $launches, live: $live}' \
        | node "$FACTORY_DIR/record.mjs")
  events=$(jq -c '.events[]' <<<"$out")
  new_snapshot=$(jq -c '.snapshot' <<<"$out")
  RECORD_EVENTS=$(jq '.events | length' <<<"$out")
  LIVE_KEYS=$live

  if $DRY_RUN; then
    [[ -n "$events" ]] && say "record: would append $RECORD_EVENTS event(s): $(jq -r '"\(.type) \(.repo)#\(.issue)"' <<<"$events" | paste -sd, -)"
    return 0
  fi
  local ev type
  while IFS= read -r ev; do
    [[ -z "$ev" ]] && continue
    append_event "$ev"
    type=$(jq -r .type <<<"$ev")
    key="$(jq -r .repo <<<"$ev")#$(jq -r .issue <<<"$ev")"
    log "event: $type $key"
    case "$type" in
      claimed) forget_run_alerts "$key" ;;
      failed) alert "failed:$key" "Ticket failed: $key" "$(jq -r '"\(.title): \(.reason)"' <<<"$ev")" "$(jq -r .url <<<"$ev")" ;;
      held)   alert "held:$key" "PR held: $key" "$(jq -r '"\(.title): \(.reason). The repo is blocked until it is merged or closed."' <<<"$ev")" "$(jq -r '.pr.url // .url' <<<"$ev")" ;;
    esac
  done <<<"$events"
  # An idle tick changes only last-tick.json.
  if [[ "$(jq -S . <<<"$new_snapshot")" != "$(jq -S . <<<"$snapshot")" ]]; then
    write_atomic "$SNAPSHOT" <<<"$new_snapshot"
  fi
}

# -------------------------------------------------------------- find work

find_work() {
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
      if ! $DRY_RUN && [[ ! -e "$STATE_DIR/alerted/needs_setup:${full//\//__}" ]]; then
        event needs_setup "repo=$full" "reason=run factory/setup-repo.sh $full"
        alert "needs_setup:$full" "Repo needs setup: $full" \
          "Ready work in $full, but setup-repo.sh has not marked it set up (or the clone at $clone is not trusted)." \
          "https://github.com/$full/issues?q=is%3Aopen+label%3Aagent%3Aready"
      fi
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

# ------------------------------------------------------- stale runs

RESUMES="$STATE_DIR/resumes.json"
ORPHANS="$STATE_DIR/orphans.json"
STALE_ACTED=0

json_file_or() { if [[ -f "$1" ]]; then cat "$1"; else echo "$2"; fi; }

# The last lines of a session's output: the transcript's last assistant text
# when it exists (claude logs is a terminal dump, unreadable in a comment).
logs_tail() {
  local s=$1 n=${2:-20} path text
  path=$(transcript_path "$s")
  # `|| true` on both: pipefail is on, and a torn transcript line (jq exits 2)
  # or an empty dump (grep -v exits 1) would fire the ERR trap from inside
  # the caller's command substitution.
  if [[ -f "$path" ]]; then
    text=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$path" 2>/dev/null | tail -n "$n" || true)
  fi
  if [[ -z "${text:-}" ]]; then
    text=$(claude logs "$(jq -r .id <<<"$s")" 2>/dev/null \
      | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g' | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n "$n" || true)
  fi
  echo "$text"
}

# Mark a launch record closed.
close_launch() {
  local key=$1 reason=$2
  launches | jq -c --arg full "${key%#*}" --argjson issue "${key#*#}" --arg ts "$TICK_TS" --arg why "$reason" \
    'map(if .full == $full and .issue == $issue and .closed_at == null then . + {closed_at: $ts, closed_reason: $why} else . end)' \
    | write_atomic "$LAUNCHES"
}

# end_closed_run <owner/repo#n>: a launched ticket closed without the record
# step seeing it leave the in-flight search (it closed between two ticks, or
# while no tick ran). Append the merged or closed event that ends its run on
# the dashboard, unless the run already has an ending.
end_closed_run() {
  local key=$1 full=${1%#*} n=${1#*#} last look json
  last=$(json_file_or "$STATE_DIR/events.jsonl" '' \
    | jq -rs --arg r "$full" --argjson n "$n" '[.[] | select(.repo == $r and .issue == $n)] | last | .type // ""')
  case "$last" in merged|closed|held|failed) return 0 ;; esac
  look=$(gh issue view "$n" --repo "$full" --json state,stateReason,title,url,closedByPullRequestsReferences 2>/dev/null) || return 0
  json=$(jq -c --arg ts "$TICK_TS" --arg r "$full" --argjson n "$n" '
    (.closedByPullRequestsReferences // [] | map(select(.merged != false)) | first) as $pr
    | {ts: $ts, repo: $r, issue: $n, title, url}
      + if $pr then {pr: {number: $pr.number, url: $pr.url}, type: "merged"}
        else {type: "closed", reason: ((.stateReason // "closed") | ascii_downcase)} end' <<<"$look")
  say "$key: event $(jq -r .type <<<"$json") (closed between ticks)"
  append_event "$json"
}

# Step 2b, every tick: resume runs that stopped, fail those that stopped
# twice, flag tickets with no agent, and fail launches /ship-bg declined.
stale_step() {
  local resumes orphans tickets launches_in l key full n s look
  resumes=$(json_file_or "$RESUMES" '{}')
  orphans=$(json_file_or "$ORPHANS" '[]')

  tickets=$(jq -c --argjson sessions "$SESSIONS" --argjson resumes "$resumes" --argjson orphans "$orphans" '
    [.[] | ("\(.repository.nameWithOwner)#\(.number)") as $k
     | {key: $k, labels: (.labels | map(.name)), session: $sessions[$k].session, live: ($sessions[$k].live // false),
        resume: $resumes[$k], orphaned: (($orphans | index($k)) != null)}]' <<<"$ISSUES")

  launches_in='[]'
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    key=$(jq -r '"\(.full)#\(.issue)"' <<<"$l"); full=${key%#*}; n=${key#*#}
    look=$(gh issue view "$n" --repo "$full" --json state,labels 2>/dev/null || echo '{"state":"OPEN","labels":[]}')
    launches_in=$(jq -c --argjson l "$l" --arg k "$key" --argjson look "$look" --argjson sessions "$SESSIONS" \
      '. + [$l + {key: $k, live: ($sessions[$k].live // false), ticket_state: $look.state, ticket_labels: ($look.labels | map(.name))}]' <<<"$launches_in")
  done < <(open_launches | jq -c '.[]')

  local out gate_is_open=false
  # A resume needs the gate; check it only when a stale ticket needs one.
  if jq -e --argjson sessions "$SESSIONS" --argjson resumes "$resumes" '
       any(.[]; (.labels | index("agent:working") or index("agent:review")) and (.live | not) and .session != null and .resume == null)' <<<"$tickets" >/dev/null; then
    check_gate
    gate_open && gate_is_open=true
  fi
  out=$(jq -nc --arg now "$TICK_TS" --argjson gate "$gate_is_open" --argjson grace "$LAUNCH_GRACE_SECS" \
          --argjson tickets "$tickets" --argjson launches "$launches_in" \
          '{now: $now, gate_open: $gate, grace_secs: $grace, tickets: $tickets, launches: $launches}' \
        | node "$FACTORY_DIR/stale.mjs")

  local a action reason
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    action=$(jq -r .action <<<"$a"); key=$(jq -r .key <<<"$a"); full=${key%#*}; n=${key#*#}
    reason=$(jq -r '.reason // ""' <<<"$a")
    s=$(jq -c '.session // empty' <<<"$a")
    say "$key: $action${reason:+ ($reason)}${s:+, session $(jq -r .id <<<"$s") $(jq -r .state <<<"$s")}"
    $DRY_RUN && continue
    STALE_ACTED=$((STALE_ACTED + 1))
    case "$action" in
      defer)
        log "$key: resume deferred, gate closed"
        ;;
      resume)
        do_resume "$key" "$s"
        ;;
      fail)
        local labels_off
        labels_off=$(jq -r '.labels | map("--remove-label", .) | .[]' <<<"$a")
        # shellcheck disable=SC2086
        gh issue edit "$n" --repo "$full" --add-label agent:failed $labels_off >/dev/null
        gh issue comment "$n" --repo "$full" --body "$reason; last lines:

\`\`\`
$(logs_tail "$s")
\`\`\`" >/dev/null
        log "$key: marked agent:failed (stale after a resume)"
        resumes=$(jq -c --arg k "$key" 'del(.[$k])' <<<"$resumes")
        close_launch "$key" "stale after a resume"
        ;;
      orphan)
        orphans=$(jq -c --arg k "$key" '. + [$k] | unique' <<<"$orphans")
        event orphan "repo=$full" "issue=$n" "reason=$reason" "url=https://github.com/$full/issues/$n" \
          "title=$(jq -r --arg k "$key" '.[] | select("\(.repository.nameWithOwner)#\(.number)" == $k) | .title' <<<"$ISSUES")"
        alert "orphan:$key" "In flight, no agent found: $key" \
          "$key is on agent:working or agent:review but no ship-$n session runs from its clone. The repo is blocked until it is dealt with." \
          "https://github.com/$full/issues/$n"
        ;;
      decline)
        local sid name
        sid=$(jq -r .session_id <<<"$a"); name=$(jq -r .name <<<"$a")
        s=$(agents_json | jq -c --arg id "$sid" '[.[] | select(.id == $id)] | first // empty')
        gh issue edit "$n" --repo "$full" --add-label agent:failed --remove-label agent:ready >/dev/null
        gh issue comment "$n" --repo "$full" --body "$reason (run \`$name\`, session \`$sid\`); last lines:

\`\`\`
$([[ -n "$s" ]] && logs_tail "$s" || echo "(session $sid not found)")
\`\`\`" >/dev/null
        log "$key: marked agent:failed (launch declined)"
        close_launch "$key" "declined"
        ;;
      close)
        [[ "$reason" == "ticket closed" ]] && end_closed_run "$key"
        close_launch "$key" "$reason"
        ;;
    esac
  done < <(jq -c '.actions[]' <<<"$out")

  $DRY_RUN && return 0
  # Forget resumes and orphans of tickets no longer in flight.
  local inflight
  inflight=$(jq -c '[.[] | "\(.repository.nameWithOwner)#\(.number)"]' <<<"$ISSUES")
  resumes=$(jq -c --argjson k "$inflight" 'with_entries(select(.key as $x | $k | index($x)))' <<<"$resumes")
  orphans=$(jq -c --argjson k "$inflight" 'map(select(. as $x | $k | index($x)))' <<<"$orphans")
  [[ "$resumes" != "$(json_file_or "$RESUMES" '{}')" ]] && write_atomic "$RESUMES" <<<"$resumes"
  [[ "$orphans" != "$(json_file_or "$ORPHANS" '[]')" ]] && write_atomic "$ORPHANS" <<<"$orphans"
  return 0
}

do_resume() {
  local key=$1 s=$2 full=${1%#*} n=${1#*#}
  local id sid state name out nid launch
  id=$(jq -r .id <<<"$s"); sid=$(jq -r .sessionId <<<"$s"); state=$(jq -r .state <<<"$s")
  name=$(jq -r '.name // empty' <<<"$s"); [[ "$name" == ship-* ]] || name="ship-$n"
  [[ "$state" == "working" ]] && claude stop "$id" >/dev/null 2>&1
  # --name, or the copy is listed under its prompt once it stops.
  if ! out=$(cd "$REPOS_DIR/${full#*/}" && claude --bg --resume "$sid" --name "$name" "continue" 2>&1); then
    log "error: resume of $key ($sid) refused: ${out//$'\n'/ | }"
    event error "repo=$full" "issue=$n" "reason=resume refused: ${out:0:400}"
    alert "error:$TICK_TS:$key" "ship-tick: resume refused" "$key: ${out:0:400}" "https://github.com/$full/issues/$n"
    return 0
  fi
  nid=$(awk -F' · ' '/^backgrounded · /{print $2; exit}' <<<"$out")
  launch=$(launches | jq -c --arg full "$full" --argjson issue "$n" '[.[] | select(.full == $full and .issue == $issue)] | last // {}')
  log "$key: resumed $id as ${nid:-?}"
  event resume "repo=$full" "issue=$n" "agent=$(jq -r '.name // ""' <<<"$launch")" "model=$(jq -r '.model // ""' <<<"$launch")" \
    "url=https://github.com/$full/issues/$n" "title=$(jq -r '.title // ""' <<<"$launch")"
  json_file_or "$RESUMES" '{}' | jq -c --arg k "$key" --arg id "${nid:-$id}" --arg ts "$TICK_TS" '. + {($k): {session_id: $id, resumed_at: $ts}}' \
    | write_atomic "$RESUMES"
  resumes=$(cat "$RESUMES")
  if [[ -n "$nid" ]]; then
    launches | jq -c --arg full "$full" --argjson issue "$n" --arg id "$nid" \
      'map(if .full == $full and .issue == $issue and .closed_at == null then . + {session_id: $id} else . end)' | write_atomic "$LAUNCHES"
  fi
}

# ------------------------------------------------------------- usage gate

# Sets GATE. Writes gate.json and gate-closed-until unless --dry-run.
check_gate() {
  local until now
  [[ -n "$GATE" ]] && return 0   # once per tick
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
  local was_open=true
  [[ -f "$GATE_FILE" ]] && was_open=$(jq -r '.open' "$GATE_FILE")
  if [[ "$open" == "true" && "$was_open" != "true" ]]; then
    event gate_opened
  elif [[ "$open" != "true" && "$was_open" == "true" ]]; then
    event gate_closed "resets_at=$resets" "reason=${err:-session $(jq -r .session_pct <<<"$GATE")%, weekly $(jq -r .weekly_pct <<<"$GATE")%}"
  fi
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
    event error "repo=$full" "issue=$issue" "reason=launch refused: ${out:0:400}"
    alert "error:$TICK_TS:$full:$issue" "ship-tick: launch refused" "$full#$issue: ${out:0:400}" \
      "https://github.com/$full/issues/$issue"
    FAILED_REPOS=$((FAILED_REPOS + 1))
    return 0
  fi
  id=$(awk -F' · ' '/^backgrounded · /{print $2; exit}' <<<"$out")
  [[ -z "$id" ]] && id=$(session_id_for_name "$name" "$clone")
  if [[ -z "$id" ]]; then
    log "error: launch of $full#$issue printed no session id: ${out//$'\n'/ | }"
    event error "repo=$full" "issue=$issue" "reason=launch printed no session id: ${out:0:400}"
    alert "error:$TICK_TS:$full:$issue" "ship-tick: launch without id" "$full#$issue: ${out:0:400}" \
      "https://github.com/$full/issues/$issue"
    FAILED_REPOS=$((FAILED_REPOS + 1))
    return 0
  fi

  log "launched $full#$issue as $name ($id) on $model"
  forget_run_alerts "$full#$issue"
  event launch "repo=$full" "issue=$issue" "title=$title" "agent=$name" "model=$model" "url=https://github.com/$full/issues/$issue"
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

# ---------------------------------------------------------------- cleanup

EVENTS_KEEP_DAYS=90

# The daily mode. Same lock as the tick, waiting for it: it rewrites
# events.jsonl, and ship-cleanup.mjs --apply stops the daemon when it sees
# no live agent, which would kill an agent a tick launched at that moment.
take_lock_wait() {
  exec 9>"$STATE_DIR/lock"
  if ! flock -w 600 9; then
    log "cleanup: the tick still holds the lock after 10 minutes, giving up"
    exit 0
  fi
}

# True when any background session is live from inside <clone>.
clone_has_live_session() {
  local clone=$1 s
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    session_is_live "$s" && return 0
  done < <(agents_json | jq -c --arg c "$clone" '.[] | select(.kind == "background" and (.cwd == $c or (.cwd | startswith($c + "/"))))')
  return 1
}

cleanup_step() {
  local script="$FACTORY_DIR/../claude/skills/ship-cleanup/ship-cleanup.mjs"
  local repos=() repo full clone todo=() skipped_live=false

  # 1. ship-cleanup.mjs in every set-up repo with nothing in flight and no
  #    live session; the worktree's copy, which updates with the factory.
  if [[ -d "$STATE_DIR/setup" ]]; then
    for repo in "$STATE_DIR/setup"/*; do
      [[ -e "$repo" ]] && repos+=("$(basename "$repo")")
    done
  fi
  for repo in "${repos[@]}"; do
    full="$OWNER_LOGIN/$repo"; clone="$REPOS_DIR/$repo"
    if [[ ! -d "$clone/.git" ]]; then
      say "cleanup: $full: no clone at $clone, skipped"
      continue
    fi
    if in_flight "$full"; then
      say "cleanup: $full: skipped, in flight: #${IN_FLIGHT_TICKETS% }"
      continue
    fi
    if clone_has_live_session "$clone"; then
      say "cleanup: $full: skipped, a live session runs from its clone"
      skipped_live=true
      continue
    fi
    todo+=("$repo")
  done
  local i n=${#todo[@]} flags out
  for ((i = 0; i < n; i++)); do
    repo=${todo[$i]}; clone="$REPOS_DIR/$repo"
    flags=(--json)
    $DRY_RUN || flags+=(--apply)
    # The daemon stop happens at most once, in the last repo, and never
    # while another repo was skipped for a live session.
    if (( i < n - 1 )) || $skipped_live; then flags+=(--keep-daemon); fi
    if out=$(cd "$clone" && node "$script" "${flags[@]}" 2>&1); then
      say "cleanup: $OWNER_LOGIN/$repo: $(jq -r '
        (if .applied then "removed" else "would remove" end) as $v
        | ([.removed[] | "\($v) \(.item)"] + [.skipped[] | "kept \(.item): \(.reason)"]) | if length == 0 then "nothing to clean up" else join("; ") end' <<<"$out" 2>/dev/null || echo "$out")"
    else
      log "cleanup: $OWNER_LOGIN/$repo: ship-cleanup.mjs failed: ${out//$'\n'/ | }"
    fi
  done

  # 2. Events older than EVENTS_KEEP_DAYS days.
  local events="$STATE_DIR/events.jsonl" cutoff before after
  if [[ -f "$events" ]]; then
    cutoff=$(date -u -d "-$EVENTS_KEEP_DAYS days" +%Y-%m-%dT%H:%M:%SZ)
    before=$(grep -c . "$events" || true)
    after=$(jq -c --arg c "$cutoff" 'select(.ts >= $c)' "$events" | grep -c . || true)
    if (( before != after )); then
      say "cleanup: events: dropping $((before - after)) of $before older than $cutoff"
      $DRY_RUN || jq -c --arg c "$cutoff" 'select(.ts >= $c)' "$events" | write_atomic "$events"
    else
      say "cleanup: events: $before kept, none older than $EVENTS_KEEP_DAYS days"
    fi
  fi

  # 3. Records of closed tickets: launches (closed or ticket closed), resumes,
  #    orphans and alert markers.
  local keys key closed='[]' state
  keys=$( { launches | jq -r '.[] | "\(.full)#\(.issue)"'
            json_file_or "$RESUMES" '{}' | jq -r 'keys[]'
            json_file_or "$ORPHANS" '[]' | jq -r '.[]'
            if [[ -d "$STATE_DIR/alerted" ]]; then
              # `|| true`: no ticket markers (only error:/needs_setup: ones) is not an error under pipefail.
              find "$STATE_DIR/alerted" -type f -printf '%f\n' | sed -n 's/^[a-z_]*://p' | { grep '#' || true; } | sed 's|__|/|'
            fi; } | sort -u)
  for key in $keys; do
    full=${key%#*}; n=${key#*#}
    state=$(gh issue view "$n" --repo "$full" --json state -q .state 2>/dev/null || echo "")
    [[ "$state" == "CLOSED" ]] && closed=$(jq -c --arg k "$key" '. + [$k]' <<<"$closed")
  done
  local drop
  drop=$(launches | jq --argjson closed "$closed" '[.[] | ("\(.full)#\(.issue)") as $k | select(.closed_at != null or (($closed | index($k)) != null))] | length')
  say "cleanup: launches: dropping $drop closed record(s); $(jq -r 'length' <<<"$closed") closed ticket(s) forgotten in resumes, orphans and alerts"
  $DRY_RUN && return 0
  launches | jq -c --argjson closed "$closed" '[.[] | ("\(.full)#\(.issue)") as $k | select(.closed_at == null and (($closed | index($k)) == null))]' | write_atomic "$LAUNCHES"
  json_file_or "$RESUMES" '{}' | jq -c --argjson closed "$closed" 'with_entries(select(.key as $k | $closed | index($k) | not))' | write_atomic "$RESUMES"
  json_file_or "$ORPHANS" '[]' | jq -c --argjson closed "$closed" 'map(select(. as $k | $closed | index($k) | not))' | write_atomic "$ORPHANS"
  for key in $(jq -r '.[]' <<<"$closed"); do
    rm -f "$STATE_DIR/alerted/"*":${key//\//__}"
  done
  # 4. The page.
  render_dashboard
}

# ------------------------------------------------------------------- main

main() {
  if $CLEANUP; then
    take_lock_wait
    OWNER_LOGIN=$(owner)
    cleanup_step
    $DRY_RUN && say "dry run: nothing changed"
    return 0
  fi
  take_lock
  OWNER_LOGIN=$(owner)
  load_agents
  record_step
  find_work

  local ready_count open_count
  ready_count=$(jq 'length' <<<"$READY")
  open_count=$(open_launches | jq 'length')
  if (( ready_count == 0 && open_count == 0 && RECORD_EVENTS == 0 && IN_FLIGHT_COUNT == 0 )); then
    say "nothing ready, nothing changed"
    save_last_tick idle
    return 0
  fi

  # A run can die while nothing on GitHub changes, so this runs even with
  # nothing ready.
  stale_step

  if (( ready_count == 0 )); then
    say "nothing ready ($IN_FLIGHT_COUNT in flight, $RECORD_EVENTS event(s), $STALE_ACTED stale action(s))"
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

# `main || …`: a non-zero return (a failed launch) must not re-enter the ERR
# trap, which would overwrite last-tick.json and alert a second time.
main || exit 1
