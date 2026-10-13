#!/usr/bin/env bash

set -e

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

pathOutput="$2"

output=$(echo '(import "nickel/mk-process-compose.ncl") (import "nickel/testnet.ncl") (import "'"$scenarioFile"'")' | nickel export --format yaml)

if [ $pathOutput ]; then
  echo "$output" > $pathOutput
else
  echo "$output"
fi
