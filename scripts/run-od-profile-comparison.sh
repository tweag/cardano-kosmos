#!/usr/bin/env bash
# FRESH_DIRECTORY [NODES=32] [SECONDS=180]
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
cd "$(dirname "$0")/.."
directory=${1:?Usage: $0 FRESH_DIRECTORY [NODES=32] [SECONDS=180]}
nodes=${2:-32}
duration=${3:-180}
[[ "$directory" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_./-]*$ && ! "$directory" =~ (^|/)\.\.(/|$) && ! -e "$directory" ]] || {
  echo "Choose a fresh, short relative directory." >&2; exit 1;
}
case "$nodes" in
  32|64|128|256) ;;
  *) echo "NODES must be 32, 64, 128 or 256." >&2; exit 1 ;;
esac
[[ "$duration" =~ ^[0-9]+$ && "$duration" -gt 0 ]] || { echo "SECONDS must be positive." >&2; exit 1; }
drain=15
((nodes < 128)) || drain=60
export OD_WARMUP_SECONDS=${OD_WARMUP_SECONDS:-30}
export OD_DRAIN_SECONDS=${OD_DRAIN_SECONDS:-$drain}
export OD_PROFILE=1
mkdir -p "$directory"
python3 - "$directory" "$nodes" "$duration" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, 'scripts')
from profile_od_run import machine_info
root, nodes, duration = Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
base = f'(import {json.dumps(str(Path("nickel/mk-sparse-scenario.ncl").resolve()))}) {nodes}'
with_delay = json.dumps(str(Path('nickel/with-delay.ncl').resolve()))
conditions = {}
for delay in (0, 50, 200):
    scenario = root / f'scenario-{delay}.ncl'
    scenario.write_text((base if delay == 0 else f'(import {with_delay}) {delay} ({base})') + '\n')
    conditions[f'd{delay}'] = {'scenario': str(scenario), 'delay_ms': delay}
(root / 'experiment.json').write_text(json.dumps({
    'nodes': nodes, 'peers_per_node': 4, 'duration_seconds': duration, 'repeats': 1,
    'machine': machine_info(), 'conditions': conditions,
}, indent=2) + '\n')
PY
for delay in 0 50 200; do
  echo "Running $nodes nodes with $delay ms added each way"
  status=0
  bash scripts/run-od-traffic-check.sh "$directory/d$delay-1" "$duration" "$directory/scenario-$delay.ncl" proxy \
    2> "$directory/d$delay-1.stderr.log" || status=$?
  mkdir -p "$directory/d$delay-1"
  printf '%s\n' "$status" > "$directory/d$delay-1/exit-status.txt"
done
python3 scripts/report_od_profile.py "$directory"
