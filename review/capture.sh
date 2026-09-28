#!/bin/zsh
# Captures one screen for the M3.5 review.
#   ./capture.sh <out-name> <INKWELL_SCREEN> [KEY=VALUE ...]
# Relaunches Inkwell in the booted simulator with fresh demo data, waits, screenshots.
set -e
cd "$(dirname "$0")"
OUT=$1; SCREEN=$2; shift 2
typeset -a envs
envs=(SIMCTL_CHILD_INKWELL_DEMO_DIR="$PWD/demo-assets" SIMCTL_CHILD_INKWELL_SCREEN="$SCREEN")
for kv in "$@"; do envs+=("SIMCTL_CHILD_$kv"); done
env "${envs[@]}" xcrun simctl launch --terminate-running-process booted studio.persimmons.inkwell >/dev/null
sleep ${WAIT:-5}
xcrun simctl io booted screenshot "$OUT.png" >/dev/null 2>&1
echo "$OUT.png"
