#!/usr/bin/env bash

set -e
set +m
shopt -s lastpipe

./scripts/run-peras-testnet.sh --no-tui > /dev/null 2>&1 &
testnet_pid=$!

cleanup() {
  echo "Stopping testnet and all child processes..."
  # Negative PID kills the entire process group
  kill -TERM -$testnet_pid 2>/dev/null || true

  process-compose down -p 3030 || true
}

timeout_seconds=180
elapsed=0
interval=10

logs_dir="devnet-env/logs"

while [ $elapsed -lt $timeout_seconds ]; do
  if [ -d $logs_dir ]; then
    if rg "Peras.Vote.Remote.Send.Init" "$logs_dir" | read -r matched_line; then
      echo "Found: ${matched_line}"
      cleanup
      exit 0
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

echo "Failure: timeout. Peras is not running"
cleanup
exit 1
