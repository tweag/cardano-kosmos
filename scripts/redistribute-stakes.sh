#!/usr/bin/env bash

set -e

if [ ! $CARDANO_CLI ]; then
  export CARDANO_CLI=$(cabal list-bin cardano-cli)
fi

scenarioArg="${1:-vanilla}"
scenarioFile="$scenarioArg"
if [ ! -f "$scenarioArg" ]; then
  scenarioFile="nickel/scenarios/$scenarioArg.ncl"
  if [ ! -f "$scenarioFile" ]; then
      echo "Unknown scenario '$scenarioArg': $scenarioFile does not exist." >&2
      usage
      exit 1
  fi
fi

DEVENV_PATH="$2"

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

echo "(import \"nickel/redistribute-stakes.ncl\")
      (import \""$scenarioFile"\")
      (import \"$DEVENV_PATH/shelley-genesis.json\")
      (import \"$DEVENV_PATH/pools-idxs-map.json\")
      " | nickel export --format json
