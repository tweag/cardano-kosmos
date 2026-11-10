#!/usr/bin/env bash

set -e

input_node_idx=$1
DEVENV_PATH="${2:-devnet-env}"

if [ $input_node_idx == "reset" ]; then
  mv "$DEVENV_PATH/cds.json.orig" "$DEVENV_PATH/cds.json"
  mv "$DEVENV_PATH/lds.json.orig" "$DEVENV_PATH/lds.json"
  exit 0
fi

node_idx=$((input_node_idx - 1))

if [ ! $node_idx ]; then
  echo "Pass an index of the node you want to isolate (starts from 1)"
  echo "E.g.: ./scripts/isolate-node.sh 1"
fi

node_port=$(cat "$DEVENV_PATH/nodes-ports.json" | jq '.['"$node_idx"']')

if [ $node_port == null ]; then
  echo "No node at the given index $input_node_idx"
  exit 0
fi

echo "Isolating node$input_node_idx at port $node_port"

# prepare orig files for envoy configs
if [ ! -f "$DEVENV_PATH/lds.json.orig" ]; then
  cp "$DEVENV_PATH/lds.json" "$DEVENV_PATH/lds.json.orig"
fi

if [ ! -f "$DEVENV_PATH/cds.json.orig" ]; then
  cp "$DEVENV_PATH/cds.json" "$DEVENV_PATH/cds.json.orig"
fi

# update original files
cat "$DEVENV_PATH/cds.json.orig" |
  jq 'del(.resources[].load_assignment.endpoints.lb_endpoints[]
            | select(.endpoint.address.socket_address.port_value == '"$node_port"'))
      ' > "$DEVENV_PATH/cds.json.new"

# we "mv" to trigger file change for envoy
mv "$DEVENV_PATH/cds.json.new" "$DEVENV_PATH/cds.json"

cat "$DEVENV_PATH/lds.json.orig" | jq 'del(.resources['"$node_idx"'])' > "$DEVENV_PATH/lds.json.new"
mv "$DEVENV_PATH/lds.json.new" "$DEVENV_PATH/lds.json"

curl -X POST http://localhost:3030/process/restart/envoy >/dev/null 2>&1

