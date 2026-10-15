#!/usr/bin/env bash
# The project's checks: syntax-check every factory script and run the Node tests.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in factory/*.sh; do
  bash -n "$f"
done
echo "bash -n: ok"

tests=(factory/*.test.mjs)
if [[ -e "${tests[0]}" ]]; then
  node --test "${tests[@]}"
else
  echo "node --test: no test files yet"
fi
