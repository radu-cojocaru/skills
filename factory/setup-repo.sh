#!/usr/bin/env bash
# setup-repo.sh <owner/repo>: prepare one repo for the factory. Idempotent.
# Clones it, creates missing labels, warns on a CLAUDE.md without the
# Shipping sections, checks the clone is trusted, and writes the marker
# state/setup/<repo> only when everything the tick needs is in place.
# Never writes ~/.claude.json.

source "$(dirname "$0")/lib.sh"
require_tools gh git jq

if [[ $# -ne 1 || "$1" != */* ]]; then
  echo "usage: $0 <owner/repo>" >&2
  exit 1
fi

FULL=$1
REPO=${FULL#*/}
CLONE="$REPOS_DIR/$REPO"
MARKER="$STATE_DIR/setup/$REPO"
ok=true

LABELS=(draft agent:ready agent:working agent:review agent:implemented agent:done agent:failed no-automerge model:opus model:fable human)

# 1. Clone.
if [[ -d "$CLONE/.git" ]]; then
  echo "clone:   found    $CLONE"
else
  gh repo clone "$FULL" "$CLONE" -- -q
  echo "clone:   created  $CLONE"
fi

# 2. Labels.
existing=$(gh label list --repo "$FULL" --limit 200 --json name -q '.[].name')
printf '\n%-20s %s\n' LABEL STATUS
for label in "${LABELS[@]}"; do
  if grep -qxF "$label" <<<"$existing"; then
    printf '%-20s found\n' "$label"
  else
    gh label create "$label" --repo "$FULL" >/dev/null
    printf '%-20s created\n' "$label"
  fi
done
echo

# 3. CLAUDE.md sections (warn only).
claude_md="$CLONE/CLAUDE.md"
for section in "Shipping" "Ship groups"; do
  if [[ -f "$claude_md" ]] && grep -qE "^#+ +$section\b" "$claude_md"; then
    echo "CLAUDE.md: has '## $section'"
  else
    echo "CLAUDE.md: warning, no '## $section' section (the ship skills read it)"
  fi
done

# 4. Trust.
if repo_is_trusted "$CLONE"; then
  echo "trust:   ok       $CLONE"
else
  ok=false
  cat <<EOF
trust:   MISSING  $CLONE
         claude --bg refuses an untrusted directory. Trust it once, by hand:

           cd $CLONE && claude

         accept the prompt, then /exit, and run this script again.
EOF
fi

# 5. Marker.
if $ok; then
  mkdir -p "$(dirname "$MARKER")"
  : >"$MARKER"
  echo "marker:  written  $MARKER"
else
  rm -f "$MARKER"
  echo "marker:  not written"
  exit 1
fi
