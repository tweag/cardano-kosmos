#!/usr/bin/env bash

set -e

echo "Building cardano packages..."

if command -v buck2 >/dev/null 2>&1; then
  buck2 build root//packages/cardano-cli/cardano-cli:cardano-cli-exe -m static
  buck2 build root//packages/cardano-node/cardano-testnet:cardano-testnet-exe -m static
  buck2 build root//packages/cardano-node/cardano-node-chairman:cardano-node-chairman -m static
  buck2 build root//packages/cardano-node/cardano-node:cardano-node-exe -m static
  buck2 build root//packages/cardano-node/cardano-tracer:cardano-tracer-exe -m static

  CARDANO_CLI=$(find "$PWD" -type f -executable -name cardano-cli -print | grep buck-out)
  CARDANO_TESTNET=$(find "$PWD" -type f -executable -name cardano-testnet -print | grep buck-out)
  CARDANO_NODE=$(find "$PWD" -type f -executable -name cardano-node -print | grep buck-out)
  CARDANO_NODE_CHAIRMAN=$(find "$PWD" -type f -executable -name cardano-node-chairman -print | grep buck-out)
  CARDANO_TRACER=$(find "$PWD" -type f -executable -name cardano-tracer -print | grep buck-out)
else
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
    .node_ports_base
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

echo "Changing configuration params"

if [ $start_directly_in_dijkstra ]; then
  jq ".TestDijkstraHardForkAtEpoch = 0 |
      .ExperimentalHardForksEnabled = true" $configurationFile | sponge $configurationFile
fi

jq --argjson trace_options "$trace_options" \
  '.TraceOptions = $trace_options |
  .TraceOptionForwarder = { queueSize: 512 }' $configurationFile | sponge $configurationFile

num_of_nodes=$(find "$DEVENV_PATH/node-data/" -mindepth 1 -type d | wc -l)

  # save the list of ports for later
node1Port=$(cat "$DEVENV_PATH/node-data/node1/port")
portsOfNodes=$(jq -r '['"$node1Port"'] + [.localRoots.[0].accessPoints[].port]' "$DEVENV_PATH/node-data/node1/topology.json")
echo $portsOfNodes > "$DEVENV_PATH/nodes-ports.json"

if [[ $proxy_mode == "envoy"* ]]; then
  testnetTopology=$(echo '((import "nickel/mk-node-topologies.ncl") "'"$ip"'" (import "'"$scenarioFile"'") '"$node_ports_base"'  '"$portsOfNodes"')' | nickel export --format json)

  for node_idx in $(seq 1 $num_of_nodes); do
    newTopology=$(echo $testnetTopology | jq '.node_topologies['"$((node_idx - 1))"']')
    echo $newTopology > "$DEVENV_PATH/node-data/node$node_idx/topology.json"
  done

  topologiesPath="$DEVENV_PATH/topologies.json"
  echo $testnetTopology | jq '.nodes' > "$topologiesPath"

  envoyConfig=$(echo '((import "nickel/mk-envoy-config.ncl") "'"$DEVENV_PATH"'" "'"$ip"'" 9091 (import "'"$scenarioFile"'") (import "'"$topologiesPath"'"))' | nickel export --format json)

  echo $envoyConfig | jq '.main' > "$DEVENV_PATH/envoy.json"
  echo $envoyConfig | jq '.clusters' > "$DEVENV_PATH/cds.json"
  echo $envoyConfig | jq '.listeners' > "$DEVENV_PATH/lds.json"
fi

echo "Ready."
