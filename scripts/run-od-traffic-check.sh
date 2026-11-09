#!/usr/bin/env bash
# Run from `nix develop`: bash scripts/run-od-traffic-check.sh FRESH_DIRECTORY [SECONDS] [SCENARIO] [direct|proxy]
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
cd "$(dirname "$0")/.."
directory=${1:?Usage: $0 FRESH_DIRECTORY [SECONDS] [SCENARIO] [direct|proxy]}
duration=${2:-90}
scenario=${3:-od-traffic}
routing=${4:-direct}
warmup=${OD_WARMUP_SECONDS:-0}
drain=${OD_DRAIN_SECONDS:-0}
profile=${OD_PROFILE:-0}
[[ "$directory" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_./-]*$ && ! "$directory" =~ (^|/)\.\.(/|$) && ! -e "$directory" ]] || {
  echo "Choose a fresh relative directory containing letters, digits, _, ., / or -." >&2; exit 1;
}
[[ "$duration" =~ ^[0-9]+$ && "$duration" -gt 0 ]] || { echo "SECONDS must be positive." >&2; exit 1; }
[[ "$warmup" =~ ^[0-9]+$ ]] || { echo "OD_WARMUP_SECONDS must be non-negative." >&2; exit 1; }
[[ "$drain" =~ ^[0-9]+$ ]] || { echo "OD_DRAIN_SECONDS must be non-negative." >&2; exit 1; }
[[ "$profile" == 0 || "$profile" == 1 ]] || { echo "OD_PROFILE must be 0 or 1." >&2; exit 1; }
[[ "$routing" == direct || "$routing" == proxy ]] || { echo "Routing must be direct or proxy." >&2; exit 1; }
[[ "$scenario" =~ ^[a-zA-Z0-9_./-]+$ ]] || { echo "Invalid scenario path." >&2; exit 1; }
[[ -f "$scenario" ]] || scenario="nickel/scenarios/$scenario.ncl"
scenario_json=$(printf '(import "nickel/export-scenario.ncl") (import "%s")\n' "$scenario" | nickel export --format json)
nodes=$(jq -r '.topology.num_of_nodes' <<< "$scenario_json")
if [[ "$routing" == direct && $(jq '.faults | length' <<< "$scenario_json") != 0 ]]; then
  echo "Fault scenarios require proxy routing." >&2; exit 1
fi
# Dedicated ports; leave an existing testnet on 3030/9090 alone.
python3 - "$routing" "$nodes" "$directory" "$scenario_json" <<'PY'
import json
import os
from pathlib import Path
import socket
import sys
sys.path.insert(0, 'scripts')
from report_od_profile import scenario_connections
scenario_connections(json.loads(sys.argv[4]))
socket_path = str((Path(sys.argv[3]) / 'socket' / f'node{sys.argv[2]}' / 'sock').resolve())
if len(os.fsencode(socket_path)) + 2 >= 108:
    raise SystemExit('Results path is too long for Cardano Unix sockets; choose a shorter directory.')
ports = [3031, 9091]
if sys.argv[1] == 'proxy':
    ports += [8475] + list(range(6001, 6001 + int(sys.argv[2])))
for port in ports:
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(('127.0.0.1', port))
PY
CARDANO_NODE=$(cabal list-bin cardano-node:exe:cardano-node)
CARDANO_TRACER=$(cabal list-bin cardano-tracer:exe:cardano-tracer)
export CARDANO_NODE CARDANO_TRACER
while IFS= read -r assignment; do
  # shellcheck disable=SC2163 # Export the NAME=value pair emitted by jq.
  export "$assignment"
done < <(
  jq -r '.env[]' <<< "$scenario_json"
)
bash scripts/setup-testnet-env.sh "$directory" "$scenario"
python3 - "$directory/nodes-ports.json" <<'PY'
import json, sys
ports = json.load(open(sys.argv[1]))
if len(ports) != len(set(ports)):
    raise SystemExit('Duplicate node listening ports; regenerate in a fresh directory before starting nodes.')
PY
for topology in "$directory"/node-data/node*/topology.json; do
  node=$(basename "$(dirname "$topology")")
  peers=$(jq -c ".topology.connections[$((${node#node} - 1))]" <<< "$scenario_json")
  if [[ "$routing" == direct ]]; then
    jq --argjson ports "$(cat "$directory/nodes-ports.json")" --argjson peers "$peers" \
      '.localRoots[0].accessPoints = [$peers[] as $peer | {address: "127.0.0.1", port: $ports[$peer - 1]}]' \
      "$topology" > "$topology.next"
  else
    printf '(import "nickel/mk-peer-topology.ncl") "127.0.0.1" 6000 %s\n' "$peers" |
      nickel export --format json > "$topology.next"
  fi
  mv "$topology.next" "$topology"
done
printf '%s\n' "$scenario_json" > "$directory/scenario.json"
printf '(import "nickel/mk-process-compose.ncl") ((import "nickel/testnet.ncl") & {directory | force = "%s", prometheus.port | force = 9091, toxiproxy.port | force = 8475, node_ports_base | force = 6000}) (import "%s") (import "%s/nodes-ports.json")\n' "$directory" "$scenario" "$directory" |
  nickel export --format yaml > "$directory/process-compose.yaml"
python3 - "$directory" "$routing" "$duration" "$warmup" "$drain" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
metadata = {'kosmos_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
            'tracked_changes': bool(subprocess.check_output(['git', 'diff', 'HEAD'])),
            'tracked_diff_sha256': hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD'])).hexdigest(),
            'routing': sys.argv[2], 'duration_seconds': int(sys.argv[3]), 'warmup_seconds': int(sys.argv[4]),
            'drain_seconds': int(sys.argv[5]),
            'forwarder_queue_size': json.loads((root / 'configuration.yaml').read_text())['TraceOptionForwarder']['queueSize'],
            'proxy_ports_base': 6000,
            'peras_env': dict(value.split('=', 1) for value in json.loads((root / 'scenario.json').read_text())['env']),
            'network': subprocess.check_output(['git', 'config', '-f', 'packages/ouroboros-network/.gitrepo', 'subrepo.commit'], text=True).strip(),
            'consensus': subprocess.check_output(['git', 'config', '-f', 'packages/ouroboros-consensus/.gitrepo', 'subrepo.commit'], text=True).strip()}
(root / 'run-parameters.json').write_text(json.dumps(metadata, indent=2) + '\n')
PY
mkdir -p "$directory/logs"
profile_pid=
if [[ "$profile" == 1 ]]; then
  python3 scripts/profile_od_run.py "$directory" > "$directory/profile.stdout.log" 2> "$directory/profile.stderr.log" &
  profile_pid=$!
fi
stop() {
  process-compose -p 3031 down || true
  if [[ -n "$profile_pid" ]]; then
    local finished_profile_pid="$profile_pid"
    profile_pid=
    touch "$directory/profile.stop"
    wait "$finished_profile_pid"
  fi
}
trap stop EXIT
processes=(chairman)
[[ "$routing" == direct ]] || processes+=(toxiproxy-setup)
process-compose -f "$directory/process-compose.yaml" -p 3031 -L "$directory/logs/process-compose.log" up "${processes[@]}" -D
deadline=$((SECONDS + 90))
while true; do
  ready=true
  for node in $(seq 1 "$nodes"); do
    [[ -S "$directory/socket/node$node/sock" ]] || ready=false
  done
  if [[ "$routing" == proxy ]]; then
    if ! curl -fsS http://127.0.0.1:8475/proxies -o "$directory/proxy-state.json" 2>/dev/null ||
       ! python3 scripts/report_od_profile.py "$directory" --check-proxies 2>/dev/null; then
      ready=false
    fi
  fi
  [[ "$ready" == false ]] || break
  ((SECONDS < deadline)) || { echo "Node startup timed out; inspect $directory/logs." >&2; exit 1; }
  sleep 1
done
echo "Warming up for $warmup seconds"
sleep "$warmup"
since=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
deadline=$((SECONDS + duration))
while ((SECONDS < deadline)); do
  if [[ -n "$profile_pid" ]] && ! kill -0 "$profile_pid" 2>/dev/null; then
    echo "Resource profiler exited early; inspect $directory/profile.stderr.log." >&2
    exit 1
  fi
  if rg -q 'TraceObject queue overflowed' "$directory"/logs/node*/stderr.log; then
    echo "Trace forwarding dropped events; capture rejected. Inspect $directory/logs/node*/stderr.log." >&2
    exit 1
  fi
  echo "Capturing OD traffic: $((deadline - SECONDS)) seconds remaining"
  remaining=$((deadline - SECONDS))
  sleep "$((remaining < 5 ? remaining : 5))"
done
until=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
python3 - "$directory" "$since" "$until" <<'PY'
import json, sys
from pathlib import Path
(Path(sys.argv[1]) / 'window.json').write_text(json.dumps({'since': sys.argv[2], 'until': sys.argv[3]}, indent=2) + '\n')
PY
echo "Allowing $drain seconds for in-flight votes to finish propagating"
sleep "$drain"
stop
trap - EXIT
echo "Analyzing OD traces and writing traffic.json/traffic.md"
python3 scripts/report_od_traffic.py "$directory" --since "$since" --until "$until" --output "$directory/traffic"
