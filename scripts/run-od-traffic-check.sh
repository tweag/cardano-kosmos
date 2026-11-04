#!/usr/bin/env bash
# Run from `nix develop`: bash scripts/run-od-traffic-check.sh FRESH_DIRECTORY [SECONDS]
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
cd "$(dirname "$0")/.."
directory=${1:?Usage: $0 FRESH_DIRECTORY [SECONDS]}
duration=${2:-90}
[[ "$directory" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_./-]*$ && ! "$directory" =~ (^|/)\.\.(/|$) && ! -e "$directory" ]] || {
  echo "Choose a fresh relative directory containing letters, digits, _, ., / or -." >&2; exit 1;
}
[[ "$duration" =~ ^[0-9]+$ && "$duration" -gt 0 ]] || { echo "SECONDS must be positive." >&2; exit 1; }
# Dedicated ports; leave an existing testnet on 3030/9090 alone.
python3 - <<'PY'
import socket
for port in (3031, 9091):
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', port))
PY
scenario=nickel/scenarios/od-traffic.ncl
CARDANO_NODE=$(cabal list-bin cardano-node:exe:cardano-node)
CARDANO_TRACER=$(cabal list-bin cardano-tracer:exe:cardano-tracer)
export CARDANO_NODE CARDANO_TRACER
while IFS= read -r assignment; do export "$assignment"; done < <(
  nickel export --format json "$scenario" | jq -r '.env[]'
)
bash scripts/setup-testnet-env.sh "$directory" "$scenario"
# Setup now routes peers through Toxiproxy. Keep this initial traffic baseline
# direct, using the actual listening ports saved by setup.
for topology in "$directory"/node-data/node*/topology.json; do
  own_port=$(cat "$(dirname "$topology")/port")
  jq --argjson ports "$(cat "$directory/nodes-ports.json")" --argjson own "$own_port" \
    '.localRoots[0].accessPoints = [$ports[] | select(. != $own) | {address: "127.0.0.1", port: .}]' \
    "$topology" > "$topology.direct"
  mv "$topology.direct" "$topology"
done
nickel export --format json "$scenario" > "$directory/scenario.json"
printf '(import "nickel/mk-process-compose.ncl") ((import "nickel/testnet.ncl") & {directory | force = "%s", prometheus.port | force = 9091}) (import "%s") (import "%s/nodes-ports.json")\n' "$directory" "$scenario" "$directory" |
  nickel export --format yaml > "$directory/process-compose.yaml"
python3 - "$directory" <<'PY'
import json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
metadata = {'kosmos_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'tracked_changes': bool(subprocess.check_output(['git', 'diff', 'HEAD'])),
            'peras_env': dict(value.split('=', 1) for value in json.loads((root / 'scenario.json').read_text())['env']),
            'network': subprocess.check_output(['git', 'config', '-f', 'packages/ouroboros-network/.gitrepo', 'subrepo.commit'], text=True).strip(),
            'consensus': subprocess.check_output(['git', 'config', '-f', 'packages/ouroboros-consensus/.gitrepo', 'subrepo.commit'], text=True).strip()}
(root / 'run-parameters.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
mkdir -p "$directory/logs"
process-compose -f "$directory/process-compose.yaml" -p 3031 -L "$directory/logs/process-compose.log" up cardano-testnet chairman -D
stop() { process-compose -p 3031 down; }
trap stop EXIT
deadline=$((SECONDS + 90))
until [[ -S "$directory/socket/node1/sock" ]]; do
  ((SECONDS < deadline)) || { echo "Node startup timed out; inspect $directory/logs." >&2; exit 1; }
  sleep 1
done
deadline=$((SECONDS + duration))
while ((SECONDS < deadline)); do
  echo "Capturing OD traffic: $((deadline - SECONDS)) seconds remaining"
  sleep 5
done
stop
trap - EXIT
set +e
python3 scripts/report_od_traffic.py "$directory" --json > "$directory/traffic.json"
status=$?
python3 scripts/report_od_traffic.py "$directory" > "$directory/traffic.md"
set -e
cat "$directory/traffic.md"
exit "$status"
