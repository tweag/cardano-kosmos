#!/usr/bin/env bash

set -e

echo "Building cardano packages..."

cabal build cardano-node-chairman cardano-testnet cardano-cli cardano-node cardano-tracer

CARDANO_CLI=$(cabal list-bin cardano-cli)
CARDANO_TESTNET=$(cabal list-bin cardano-testnet)

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

jq ".securityParam = $security_param_k |
    .slotLength = $slot_length_seconds |
    .epochLength = $epoch_length_slots" $shelleyGenesisFile | sponge $shelleyGenesisFile

jq ".protocolConsts.k = $security_param_k" $byronGenesisFile | sponge $byronGenesisFile

echo "Changing configuration params"

if [ $start_directly_in_dijkstra ]; then
  jq ".TestDijkstraHardForkAtEpoch = 0" $configurationFile | sponge $configurationFile
fi

# prepare pools.json
json_output="{}"

for pool_dir in "${DEVENV_PATH}"/pools-keys/pool*; do
  pool_name=$(basename "$pool_dir")
  pool_index=$(echo "$pool_name" | sed 's/[^0-9]//g')

  pool_id=$($CARDANO_CLI dijkstra stake-pool id --cold-verification-key-file "$pool_dir/cold.vkey" --output-hex | tr -d '[:space:]')
  
  # Append the key-value pair to the JSON object using jq
  if [ -n "$pool_id" ]; then
    json_output=$(echo "$json_output" | jq --arg key "$pool_id" --argjson val "$pool_index" '. + {($key): $val}')
  fi
done

echo "$json_output" > "$DEVENV_PATH"/pools-idxs-map.json

# TODO: implement redistribution of stakes
echo "(import \"nickel/redistribute-stakes.ncl\")
      (import \""$scenarioFile"\")
      (import \"$DEVENV_PATH/shelley-genesis.json\")
      (import \"$DEVENV_PATH/pools-idxs-map.json\")
      " | nickel export --format json > "$DEVENV_PATH/new_initial_funds.json" 

# TODO: move to the nickel config
trace_options='{"" : {"severity": "Info", "backends": ["Stdout HumanFormatColoured"]}}'

jq --argjson trace_options "$trace_options" '.TraceOptions = $trace_options' $configurationFile | sponge $configurationFile

# TODO: add toxiproxy ports map supports

echo "Ready."
