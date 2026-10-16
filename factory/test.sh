#!/usr/bin/env bash
# The project's checks: syntax-check every factory script and run the Node tests.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in factory/*.sh; do
  bash -n "$f"
done
echo "bash -n: ok"

# transcript_path finds a session's transcript by id, wherever Claude Code
# filed it: a /ship-bg run moves into a worktree whose folder name has "--"
# for "/.", while the session's .cwd still names the clone.
(
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  export HOME=$tmp
  source factory/lib.sh
  dir="$HOME/.claude/projects/-home-dev-app--claude-worktrees-issue-7"
  mkdir -p "$dir" && : >"$dir/abc-123.jsonl"
  got=$(transcript_path '{"cwd":"/home/dev/app","sessionId":"abc-123"}')
  [[ "$got" == "$dir/abc-123.jsonl" ]] || { echo "transcript_path: got '$got'" >&2; exit 1; }
  got=$(transcript_path '{"cwd":"/home/dev/app","sessionId":"missing"}')
  [[ -z "$got" ]] || { echo "transcript_path: expected nothing, got '$got'" >&2; exit 1; }
  got=$(transcript_path '{"cwd":"/home/dev/app"}')
  [[ -z "$got" ]] || { echo "transcript_path: no sessionId, got '$got'" >&2; exit 1; }
)
echo "transcript_path: ok"

tests=(factory/*.test.mjs)
if [[ -e "${tests[0]}" ]]; then
  node --test "${tests[@]}"
else
  echo "node --test: no test files yet"
fi
