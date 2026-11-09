#!/usr/bin/env bash

set -euo pipefail

echo "Building cardano packages..."

cabal build cardano-node-chairman cardano-testnet cardano-cli cardano-node cardano-tracer

CARDANO_CLI=$(cabal list-bin cardano-cli)
CARDANO_TESTNET=$(cabal list-bin cardano-testnet)

export CARDANO_CLI CARDANO_TESTNET

DEVENV_PATH="${1:-devnet-env}"

echo "Setting up Peras devenv at ./${DEVENV_PATH}"

if [ -d "$DEVENV_PATH" ]; then
  echo "./${DEVENV_PATH} exists already, removing"
  rm -rf -- "$DEVENV_PATH"
fi

mkdir -p -- "$DEVENV_PATH"

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
    .activeSlotsCoeff = $active_slot_coeff_f |
    .extraConfig.initialFunds = $new_initial_funds" "$shelleyGenesisFile" | sponge "$shelleyGenesisFile"

jq ".protocolConsts.k = $security_param_k" "$byronGenesisFile" | sponge "$byronGenesisFile"

echo "Changing configuration params"

if [ "$start_directly_in_dijkstra" = true ]; then
  jq ".TestDijkstraHardForkAtEpoch = 0 |
      .ExperimentalHardForksEnabled = true" "$configurationFile" | sponge "$configurationFile"
fi

trace_options=$(echo '(import "nickel/testnet.ncl")' | nickel export --format json | jq -r '.trace_options')

jq --argjson trace_options "$trace_options" ".TraceOptions = $trace_options |
  .TraceOptionForwarder = { queueSize: 16384 }" "$configurationFile" | sponge "$configurationFile"

# substitute ports for toxiproxy
read -r \
  ip \
  node_ports_base \
< <(nickel export nickel/testnet.ncl | jq -r '[
    .ip,
    .node_ports_base
  ] | @tsv')

num_of_nodes=$(find "$DEVENV_PATH/node-data/" -mindepth 1 -maxdepth 1 -type d | wc -l)

# save the list of ports for later
portsOfNodes=$(for node_idx in $(seq 1 "$num_of_nodes"); do
  cat "$DEVENV_PATH/node-data/node$node_idx/port"
  echo
done | jq -s '.')

printf '%s\n' "$portsOfNodes" > "$DEVENV_PATH/nodes-ports.json"

connections=$(printf '(import "%s").topology.connections\n' "$scenarioFile" | nickel export --format json)
for node_idx in $(seq 1 "$num_of_nodes"); do
  peers=$(jq -c ".[$((node_idx - 1))]" <<< "$connections")
  newTopology=$(printf '(import "nickel/mk-peer-topology.ncl") "%s" %s %s\n' "$ip" "$node_ports_base" "$peers" | nickel export --format json)
  printf '%s\n' "$newTopology" > "$DEVENV_PATH/node-data/node$node_idx/topology.json"
done

echo "Ready."
