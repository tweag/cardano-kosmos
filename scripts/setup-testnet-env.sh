#!/usr/bin/env bash

set -e

echo "Building cardano packages..."

if command -v buck2 >/dev/null 2>&1; then
  CARDANO_CLI=$(buck2 build root//packages/cardano-cli/cardano-cli:cardano-cli-exe -m static --show-full-simple-output)
  CARDANO_TESTNET=$(buck2 build root//packages/cardano-node/cardano-testnet:cardano-testnet-exe -m static --show-full-simple-output)
  CARDANO_NODE_CHAIRMAN=$(buck2 build root//packages/cardano-node/cardano-node-chairman:cardano-node-chairman -m static --show-full-simple-output)
  CARDANO_NODE=$(buck2 build root//packages/cardano-node/cardano-node:cardano-node-exe -m static --show-full-simple-output)
  CARDANO_TRACER=$(buck2 build root//packages/cardano-node/cardano-tracer:cardano-tracer-exe -m static --show-full-simple-output)
else
  # plutus-core is built in place, since it depends on the vendored
  # cardano-strict-containers. Several of its components start at once and
  # cabal unpacks the source once per component without a lock, which can
  # leave truncated files. Building it with a single job unpacks it only once.
  cabal build -j1 plutus-core
  cabal build cardano-node-chairman cardano-testnet cardano-cli cardano-node cardano-tracer

  CARDANO_CLI=$(cabal list-bin cardano-cli)
  CARDANO_TESTNET=$(cabal list-bin cardano-testnet)
  CARDANO_NODE=$(cabal list-bin cardano-node)
  CARDANO_NODE_CHAIRMAN=$(cabal list-bin cardano-node-chairman)
  CARDANO_TRACER=$(cabal list-bin cardano-tracer:cardano-tracer)
fi

export CARDANO_CLI CARDANO_TESTNET CARDANO_NODE CARDANO_NODE_CHAIRMAN CARDANO_TRACER

DEVENV_PATH="${1:-devnet-env}"

echo "Setting up Peras devenv at ./${DEVENV_PATH}"

if [ -d "$DEVENV_PATH" ]; then
  echo "./${DEVENV_PATH} exists already, removing"
  rm -rf ${DEVENV_PATH}
fi

mkdir -p ${DEVENV_PATH}

scenarioArg="${2:-vanilla}"
scenarioFile="$scenarioArg"
if [ ! -f "$scenarioArg" ]; then
  scenarioFile="nickel/scenarios/$scenarioArg.ncl"
  if [ ! -f "$scenarioFile" ]; then
      echo "Unknown scenario '$scenarioArg': $scenarioFile does not exist." >&2
      exit 1
  fi
fi

echo "Using: $scenarioFile"

cardano_binaries='{
  "cardano_node": "'"$CARDANO_NODE"'",
  "cardano_cli": "'"$CARDANO_CLI"'",
  "cardano_testnet": "'"$CARDANO_TESTNET"'",
  "cardano_node_chairman": "'"$CARDANO_NODE_CHAIRMAN"'",
  "cardano_tracer": "'"$CARDANO_TRACER"'"
}'

echo $cardano_binaries > "$DEVENV_PATH/cardano_binaries.json"

testnet_config=$(echo '(import "nickel/mk-testnet-config.ncl") (import "'"$DEVENV_PATH/cardano_binaries.json"'") (import "nickel/testnet.ncl") (import "'"$scenarioFile"'")' | nickel export --format json)

trace_options=$(echo $testnet_config | jq -r '.trace_options')

# cardano-tracer setup
cardano_tracer_config=$(echo $testnet_config | jq -r '.cardano_tracer_config')
echo $cardano_tracer_config > "$DEVENV_PATH/cardano-tracer-config.json"
mkdir -p "$DEVENV_PATH/socket"

read -r \
  nodes_arg \
  testnet_magic \
  epoch_length_slots \
  slot_length_seconds \
  security_param_k \
  active_slot_coeff_f \
  num_dreps \
  max_lovelace_supply \
  start_directly_in_dijkstra \
  proxy_mode \
  ip \
  node_ports_base \
  peras_genesis \
  < <(echo $testnet_config | jq -r '[
    .nodes_arg,
    .testnet_magic,
    .genesis.epoch_length_slots,
    .genesis.slot_length_seconds,
    .genesis.security_param_k,
    .genesis.active_slot_coeff_f,
    .genesis.num_dreps,
    .genesis.max_lovelace_supply,
    .genesis.start_directly_in_dijkstra,
    
    .proxy,
    .ip,
    .node_ports_base,
    (.genesis.peras | tojson)
  ] | @tsv')

echo "Running cardano_testnet create-env"

"$CARDANO_TESTNET" create-env \
  --nodes="$nodes_arg" \
  --num-dreps="$num_dreps" \
  --max-lovelace-supply="$max_lovelace_supply" \
  --testnet-magic="$testnet_magic" \
  --output="$DEVENV_PATH"

# generated config files
shelleyGenesisFile="${DEVENV_PATH}/shelley-genesis.json"
byronGenesisFile="${DEVENV_PATH}/byron-genesis.json"
configurationFile="${DEVENV_PATH}/configuration.yaml"

echo "Changing genesis params"

new_initial_funds=$(./scripts/redistribute-stakes.sh "$scenarioArg" "$DEVENV_PATH")

jq ".securityParam = $security_param_k |
    .slotLength = $slot_length_seconds |
    .epochLength = $epoch_length_slots |
    .extraConfig.initialFunds = $new_initial_funds" $shelleyGenesisFile | sponge $shelleyGenesisFile

jq ".protocolConsts.k = $security_param_k" $byronGenesisFile | sponge $byronGenesisFile

# create-testnet-data writes the full PlutusV4 parameter list, but the ledger's
# Dijkstra genesis decoder only accepts the initial 251 parameters.
dijkstraGenesisFile="${DEVENV_PATH}/dijkstra-genesis.json"
jq '.plutusV4CostModel |= .[:251]' $dijkstraGenesisFile | sponge $dijkstraGenesisFile

jq --argjson peras "$peras_genesis" '. * $peras' $dijkstraGenesisFile | sponge $dijkstraGenesisFile

# TODO make a configurable parameter
jq ".perasBootstrapRound = 1" $dijkstraGenesisFile | sponge $dijkstraGenesisFile

echo "Changing configuration params"

if [ $start_directly_in_dijkstra ]; then
  jq ".TestDijkstraHardForkAtEpoch = 0 |
      .ExperimentalHardForksEnabled = true" $configurationFile | sponge $configurationFile
fi

dijkstraGenesisHash=$($CARDANO_CLI hash genesis-file --genesis "$DEVENV_PATH/dijkstra-genesis.json")
shelleyGenesisHash=$($CARDANO_CLI hash genesis-file --genesis "$DEVENV_PATH/shelley-genesis.json")

jq --argjson trace_options "$trace_options" \
  '.TraceOptions = $trace_options |
  .Configuration.Testing.DijkstraGenesisHash = "'$dijkstraGenesisHash'" |
  .Configuration.Protocol.ShelleyGenesisHash = "'$shelleyGenesisHash'" |
  .TraceOptionForwarder = { queueSize: 512 }' $configurationFile | sponge $configurationFile

num_of_nodes=$(find "$DEVENV_PATH/node-data/" -mindepth 1 -type d | wc -l)

# save the list of ports for later
node1Port=$(cat "$DEVENV_PATH/node-data/node1/port")
portsOfNodes=$(jq -r '['"$node1Port"'] + [.localRoots.[0].accessPoints[].port]' "$DEVENV_PATH/node-data/node1/topology.json")
echo $portsOfNodes > "$DEVENV_PATH/nodes-ports.json"

if [[ $proxy_mode == "envoy"* ]]; then
  use_proxy=true
else
  use_proxy=false
fi

# Apply the scenario's links in both modes; only the target port differs.
testnetTopology=$(echo '((import "nickel/mk-node-topologies.ncl") "'"$ip"'" (import "'"$scenarioFile"'") '"$use_proxy"' '"$node_ports_base"'  '"$portsOfNodes"')' | nickel export --format json)

for node_idx in $(seq 1 $num_of_nodes); do
  newTopology=$(echo $testnetTopology | jq '.node_topologies['"$((node_idx - 1))"']')
  echo $newTopology > "$DEVENV_PATH/node-data/node$node_idx/topology.json"
  mkdir -p "$DEVENV_PATH/logs/node$node_idx"
  mkdir -p "$DEVENV_PATH/socket/node$node_idx"
done

topologiesPath="$DEVENV_PATH/topologies.json"
echo $testnetTopology | jq '.nodes' > "$topologiesPath"

if [[ $proxy_mode == "envoy"* ]]; then
  envoyConfig=$(echo '((import "nickel/mk-envoy-config.ncl") "'"$DEVENV_PATH"'" "'"$ip"'" 9091 (import "'"$scenarioFile"'") (import "'"$topologiesPath"'"))' | nickel export --format json)

  echo $envoyConfig | jq '.main' > "$DEVENV_PATH/envoy.json"
  echo $envoyConfig | jq '.clusters' > "$DEVENV_PATH/cds.json"
  echo $envoyConfig | jq '.listeners' > "$DEVENV_PATH/lds.json"
fi

echo "Ready."
