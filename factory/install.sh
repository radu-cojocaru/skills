#!/usr/bin/env bash
# One-time, idempotent setup of the ship factory on this machine.
# Creates the ~/skills-factory worktree, factory/.local/ and config.env.
# Never edits the crontab and never runs sudo: it prints those steps.

source "$(dirname "$0")/lib.sh"
require_tools git

WORKTREE="$HOME/skills-factory"
REPO_DIR=$(cd "$FACTORY_DIR/.." && pwd)

if [[ -e "$WORKTREE" ]]; then
  log "worktree exists: $WORKTREE"
else
  git -C "$REPO_DIR" fetch -q origin
  git -C "$REPO_DIR" worktree add --detach "$WORKTREE" origin/main
  log "created worktree: $WORKTREE"
fi

WT_LOCAL="$WORKTREE/factory/.local"
mkdir -p "$WT_LOCAL/state"

if [[ -f "$WT_LOCAL/config.env" ]]; then
  log "config exists: $WT_LOCAL/config.env"
else
  cp "$FACTORY_DIR/config.example.env" "$WT_LOCAL/config.env"
  chmod 600 "$WT_LOCAL/config.env"
  log "created config: $WT_LOCAL/config.env"
fi

cat <<EOF

Config:   $WT_LOCAL/config.env
State:    $WT_LOCAL/state
Worktree: $WORKTREE (detached on origin/main; cron updates it before every tick)

Add these two lines to your crontab (crontab -e) once the trial loop is stopped:

*/5 * * * * git -C ~/skills-factory fetch -q && git -C ~/skills-factory checkout -q --detach origin/main && ~/skills-factory/factory/ship-tick.sh 2>&1 | logger -t ship-tick
17 4 * * *  ~/skills-factory/factory/ship-tick.sh --cleanup 2>&1 | logger -t ship-tick

Dashboard (one-time sudo steps, not run by this script):

sudo mkdir -p $WWW_DIR && sudo chown $(id -un) $WWW_DIR && sudo chmod 755 $WWW_DIR
sudo mkdir -p /etc/caddy/conf.d
sudo cp $WORKTREE/factory/ship-factory.caddy /etc/caddy/conf.d/ship-factory.caddy
# Add to the host's main Caddyfile, once:  import /etc/caddy/conf.d/*.caddy
sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy

Then run factory/setup-repo.sh <owner/repo> for each repo the factory should ship.
Logs: journalctl -t ship-tick
EOF
