#!/usr/bin/env sh
# Runs the fleet scripts against a stand-in for ComputerCraft, so movement,
# digging and the coordinator protocol can be checked without Minecraft.
#
#   sh test/run.sh
#
# Run it from the repository root. Needs a lua interpreter on PATH.

set -e
cd "$(dirname "$0")/.."

status=0

for file in *.lua; do
  luac -p "$file" || status=1
done
echo "syntax ok"

for suite in test/fleet_test.lua test/scenarios_test.lua test/update_test.lua; do
  echo
  echo "--- $suite ---"
  lua "$suite" || status=1
done

exit $status
