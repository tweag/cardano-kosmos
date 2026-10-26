#!/usr/bin/env bash

set -e

# Attempt to use the argument as a filepath, or as a slug if there is no such file.
scenarioFile="${1:-vanilla}"
if [ ! -f "$scenarioFile" ]; then
  scenarioSlug="$scenarioFile"
  scenarioFile="nickel/scenarios/$scenarioSlug.ncl"
  if [ ! -f "$scenarioFile" ]; then
      echo "Unknown scenario '$scenarioSlug': $scenarioFile does not exist." >&2
      usage
      exit 1
  fi
fi

DEVENV_PATH="$2"
pathOutput="$DEVENV_PATH/process-compose.yaml"

portsOfNodes=$(cat "$DEVENV_PATH/nodes-ports.json")
output=$(echo '(import "nickel/mk-process-compose.ncl") (import "nickel/testnet.ncl") (import "'"$scenarioFile"'") '"$portsOfNodes"'' | nickel export --format yaml)

echo "$output" > "$pathOutput"
