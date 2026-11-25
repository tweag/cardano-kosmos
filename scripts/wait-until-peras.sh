#!/usr/bin/env bash

set -e
set +m
shopt -s lastpipe

timeout_seconds=$1

./scripts/run-peras-testnet.sh --no-tui > /dev/null 2>&1 &
testnet_pid=$!

cleanup() {
  echo "Stopping testnet and all child processes..."
  # Negative PID kills the entire process group
  kill -TERM -$testnet_pid 2>/dev/null || true

  process-compose down -p 3030 || true
}

elapsed=0
interval=10

logs_dir="devnet-env/logs"

found_peras="false"

while [ $elapsed -lt $timeout_seconds ]; do
  if [ -d $logs_dir ]; then
    if [[ $found_peras != "true" ]]; then
      if rg "Peras.Vote.Remote.Send.Init" "$logs_dir" | read -r matched_line; then
        echo "Found: ${matched_line}"
        found_peras=true
      fi
    fi
  fi

  if ! kill -0 $testnet_pid 2>/dev/null; then
    echo "The testnet has stopped unexpectedly."
    exit 1
  fi

  sleep $interval 
  elapsed=$((elapsed + interval))
  echo "(${elapsed}s / ${timeout_seconds}s elapsed)"
done

if [[ $found_peras == "false" ]]; then
  echo "Failure: timeout. Peras is not running"
  cleanup
  exit 1
fi

cleanup
exit 0
