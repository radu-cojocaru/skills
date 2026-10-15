#!/usr/bin/env bash
# Shared by every factory script: source "$(dirname "$0")/lib.sh".
# Sets HOME and PATH (cron's environment is minimal), locates the factory
# folders, loads config.env with defaults, and provides the helpers below.

set -euo pipefail

# Cron runs without HOME on some systems.
if [[ -z "${HOME:-}" ]]; then
  HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
  export HOME
fi

# shellcheck disable=SC2155
FACTORY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCAL_DIR="$FACTORY_DIR/.local"
STATE_DIR="$LOCAL_DIR/state"
CONFIG="$LOCAL_DIR/config.env"

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

# Defaults for every missing key. OWNER defaults lazily, see owner().
: "${SESSION_MAX_PCT:=70}"
: "${WEEKLY_MAX_PCT:=90}"
: "${DEFAULT_MODEL:=sonnet}"
: "${REPOS_DIR:=$HOME}"
: "${EXCLUDE_REPOS:=}"
: "${WWW_DIR:=/srv/ship-factory/www}"
: "${PUSHOVER_TOKEN:=}"
: "${PUSHOVER_USER:=}"
: "${STALE_MINUTES:=60}"
: "${NODE_BIN_DIR:=$HOME/.local/share/fnm/aliases/default/bin}"

# node comes from fnm, whose shell hook cron never runs; claude is in ~/.local/bin.
export PATH="$NODE_BIN_DIR:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2
}

# Exit 2 naming the first tool that is not on PATH.
require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      log "error: $tool is not on PATH ($PATH)"
      exit 2
    fi
  done
}

# write_atomic <path>: stdin -> <path>.tmp.$$ -> mv over <path>.
write_atomic() {
  local path=$1 tmp
  tmp="$path.tmp.$$"
  mkdir -p "$(dirname "$path")"
  cat >"$tmp"
  mv -f "$tmp" "$path"
}

# OWNER from config, else the logged-in gh user. Cached for the process.
owner() {
  if [[ -z "${OWNER:-}" ]]; then
    OWNER=$(gh api user -q .login)
  fi
  echo "$OWNER"
}

# alert <key> <title> <message> [url]: one Pushover alert per key, ever.
# GitHub does not notify you about your own account's actions, so this is the
# only notification path. Without the keys, log only. A failed POST is logged
# and never fails the caller.
alert() {
  local key=$1 title=$2 message=$3 url=${4:-}
  local file="$STATE_DIR/alerted/${key//\//__}"
  if [[ -e "$file" ]]; then
    return 0
  fi
  log "alert [$key] $title: $message ${url:+($url)}"
  if [[ -n "$PUSHOVER_TOKEN" && -n "$PUSHOVER_USER" ]]; then
    if ! curl -s -m 10 -o /dev/null -X POST https://api.pushover.net/1/messages.json \
        --data-urlencode "token=$PUSHOVER_TOKEN" \
        --data-urlencode "user=$PUSHOVER_USER" \
        --data-urlencode "title=$title" \
        --data-urlencode "message=$message" \
        --data-urlencode "url=$url"; then
      log "alert [$key]: pushover POST failed"
    fi
  fi
  mkdir -p "$(dirname "$file")"
  : >"$file"
}

# append_event <json>: one line onto state/events.jsonl, through a temp file.
# Call it only while holding the tick's lock.
append_event() {
  local events="$STATE_DIR/events.jsonl" line
  line=$(jq -c . <<<"$1")
  { if [[ -f "$events" ]]; then cat "$events"; fi; echo "$line"; } | write_atomic "$events"
}

# launches_json: launches.json, or [] when there is none.
launches_json() {
  if [[ -f "$STATE_DIR/launches.json" ]]; then cat "$STATE_DIR/launches.json"; else echo '[]'; fi
}

# agents_json: `claude agents --json --all`, fetched once per process. A local
# call that starts no session. Set AGENTS_JSON to override.
agents_json() {
  if [[ -z "${AGENTS_JSON:-}" ]]; then
    AGENTS_JSON=$(claude agents --json --all 2>/dev/null || true)
    [[ -z "$AGENTS_JSON" ]] && AGENTS_JSON='[]'
  fi
  echo "$AGENTS_JSON"
}

# ticket_session <owner/repo> <issue>: the background session for a ticket,
# as one JSON object, or nothing. Its name is ship-<n> or ship-<n>-… AND its
# cwd is the repo's clone or inside it: issue numbers repeat across repos.
# The one recorded in launches.json wins; else the newest startedAt.
ticket_session() {
  local full=$1 issue=$2 clone preferred
  clone="$REPOS_DIR/${full#*/}"
  preferred=$(launches_json | jq -r --arg full "$full" --argjson issue "$issue" \
    '[.[] | select(.full == $full and .issue == $issue)] | last | .session_id // empty')
  agents_json | jq -c --arg n "$issue" --arg c "$clone" --arg pref "$preferred" '
    [.[] | select(.kind == "background"
                  and ((.name == "ship-" + $n) or (.name | startswith("ship-" + $n + "-")))
                  and (.cwd == $c or (.cwd | startswith($c + "/"))))]
    | ((map(select($pref != "" and .id == $pref)) | first) // (sort_by(.startedAt) | last) // empty)'
}

# transcript_path <session json>: ~/.claude/projects/<cwd with / -> ->/<sessionId>.jsonl
transcript_path() {
  local cwd sid
  cwd=$(jq -r '.cwd' <<<"$1")
  sid=$(jq -r '.sessionId' <<<"$1")
  echo "$HOME/.claude/projects/${cwd//\//-}/$sid.jsonl"
}

# session_is_live <session json>: state working or blocked AND the transcript
# changed in the last STALE_MINUTES. A session that dies mid-step keeps
# reading `working` forever, and the daemon restores that state on restart
# (see ticketIsClosed() in claude/skills/ship-cleanup/ship-cleanup.mjs).
session_is_live() {
  local s=$1 state path
  [[ -z "$s" ]] && return 1
  state=$(jq -r '.state // ""' <<<"$s")
  [[ "$state" == "working" || "$state" == "blocked" ]] || return 1
  path=$(transcript_path "$s")
  [[ -f "$path" ]] || return 1
  [[ -n "$(find "$path" -mmin "-$STALE_MINUTES" 2>/dev/null)" ]]
}

# live_session <owner/repo> <issue>: prints the id of the ticket's live
# session, or nothing.
live_session() {
  local s
  s=$(ticket_session "$1" "$2")
  if session_is_live "$s"; then
    jq -r '.id' <<<"$s"
  fi
}

# repo_is_trusted <dir>: true when <dir> or any ancestor has accepted the
# trust dialog in ~/.claude.json. Trust is inherited, so a clone inside a
# trusted folder passes. Reads the file only; never writes it.
repo_is_trusted() {
  local dir=$1 claude_json="$HOME/.claude.json"
  [[ -f "$claude_json" ]] || return 1
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  while :; do
    if [[ "$(jq -r --arg d "$dir" '.projects[$d].hasTrustDialogAccepted // false' "$claude_json")" == "true" ]]; then
      return 0
    fi
    [[ "$dir" == "/" ]] && return 1
    dir=$(dirname "$dir")
  done
}
