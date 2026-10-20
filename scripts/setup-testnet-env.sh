#!/usr/bin/env bash

set -e

echo "Building cardano packages..."

cabal build cardano-node-chairman cardano-testnet cardano-cli cardano-node cardano-tracer

CARDANO_CLI=$(cabal list-bin cardano-cli)
CARDANO_TESTNET=$(cabal list-bin cardano-testnet)

export CARDANO_CLI CARDANO_TESTNET

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
< <(echo '(import "nickel/mk-testnet-config.ncl") (import "'"$scenarioFile"'")' | nickel export --format json | jq -r '[
    .nodes_arg,
    .testnet_magic,

    .genesis.epoch_length_slots,
    .genesis.slot_length_seconds,
    .genesis.security_param_k,
    .genesis.active_slot_coeff_f,
    .genesis.num_dreps,
    .genesis.max_lovelace_supply,
    .genesis.start_directly_in_dijkstra
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
  jq ".TestDijkstraHardForkAtEpoch = 0" $configurationFile | sponge $configurationFile
  jq '.ExperimentalHardForksEnabled = true' $configurationFile | sponge $configurationFile
fi

# TODO: move to the nickel config
trace_options='{"" : {"severity": "Notice", "backends": ["Stdout HumanFormatColoured"]},"Peras" : {"severity": "Debug", "backends": ["EKGBackend", "Forwarder"],"detail":"DNormal"},"ChainDB.PerasVoteDbEvent": {"severity": "Debug", "backends": ["EKGBackend", "Forwarder"]},"Startup": {"severity": "Info", "backends": ["EKGBackend", "Forwarder"]},"ChainDB.PerasCertDbEvent":{"severity": "Debug", "backends": ["EKGBackend", "Forwarder"]}}'

jq --argjson trace_options "$trace_options" '.TraceOptions = $trace_options' $configurationFile | sponge $configurationFile
jq '.TraceOptionForwarder = { queueSize: 512 }' $configurationFile | sponge $configurationFile

# substitute ports for toxiproxy
read -r \
  ip \
  node_ports_base \
< <(nickel export nickel/testnet.ncl | jq -r '[
    .ip,
    .node_ports_base
  ] | @tsv')

num_of_nodes=$(find "$DEVENV_PATH/node-data/" -mindepth 1 -type d | wc -l)

# save the list of ports for later
node1Port=$(cat "$DEVENV_PATH/node-data/node1/port")
portsOfNodes=$(jq -r '['"$node1Port"'] + [.localRoots.[0].accessPoints[].port]' "$DEVENV_PATH/node-data/node1/topology.json")

echo $portsOfNodes > "$DEVENV_PATH/nodes-ports.json"

for node_idx in $(seq 1 $num_of_nodes); do
  newTopology=$(echo '(import "nickel/mk-node-topology.ncl") "'"$ip"'" '"$node_ports_base"' '"$node_idx"' '"$num_of_nodes"'' | nickel export --format json)
  echo $newTopology > "$DEVENV_PATH/node-data/node$node_idx/topology.json"
done

echo "Ready."
