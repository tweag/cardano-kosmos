#!/usr/bin/env bash

set -e

cleanup() {
  echo "Shutting down process-compose and child processes..."
  process-compose down -p 3030 || true

  timeout_limit=15
  elapsed_wait=0

  while pgrep -f "process-compose" > /dev/null && [ $elapsed_wait -lt $timeout_limit ]; do
    sleep 1
    elapsed_wait=$((elapsed_wait + 1))
  done

  sleep 5

  pkill -9 -f cardano-node-chairman || true
  pkill -9 -f cardano-testnet || true
  pkill -9 -f cardano-node || true
  pkill -9 -f cardano-tracer || true
  pkill -9 -f victoria-logs || true
  pkill -9 -f victoria-metrics || true
  pkill -9 -f vlagent || true
}
trap cleanup EXIT INT TERM

usage() {
    echo "Usage: $0 [SCENARIO]" >&2
    echo "  SCENARIO defaults to 'vanilla' if omitted." >&2
    echo "Available scenarios:" >&2
    for f in nickel/scenarios/*.ncl; do
        [ -e "$f" ] && echo "  $(basename "$f" .ncl)" >&2
    done
}

DEVENV_PATH="devnet-env"
# run process-compose with tui by default
PC_DISABLE_TUI=false

runTestnet() {
    for arg in "$@"; do
        case "$arg" in
            --no-tui)
                # otherwise in detached mode
                PC_DISABLE_TUI=true
                shift
                ;;
        esac
    done

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

    # Setup devnet-env
    if [ ! -d "$DEVENV_PATH" ]; then
      bash ./scripts/setup-testnet-env.sh "$DEVENV_PATH"
    fi

    echo "Running: $scenarioFile"
    export PC_DISABLE_TUI
    echo '(import "nickel/mk-process-compose.ncl") (import "nickel/testnet.ncl") (import "'"$scenarioFile"'")' | nickel export --format yaml > "$DEVENV_PATH"/process-compose.yaml
    process-compose up \
        -f "$DEVENV_PATH"/process-compose.yaml \
        -p 3030 \
        -L "$DEVENV_PATH"/logs/process-compose.log 2>/dev/null
}

case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
    *)
        runTestnet "${1:-}"
        ;;
esac
