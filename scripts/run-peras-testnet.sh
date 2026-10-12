#!/usr/bin/env bash

set -e

cleanup() {
  echo "Shutting down process-compose and child processes..."
  pkill -TERM -P $$ 2>/dev/null
  sleep 1
  pkill -KILL -P $$ 2>/dev/null

  # annoying
  pkill cardano-node
  pkill cardano-tracer
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

runTestnet() {
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

    echo "Using: $scenarioFile"
    echo '(import "nickel/mk-process-compose.ncl") (import "nickel/testnet.ncl") (import "'"$scenarioFile"'")' | nickel export --format yaml > "$DEVENV_PATH"/process-compose.yaml
    process-compose \
        -f "$DEVENV_PATH"/process-compose.yaml \
        -p 3030 \
        -L "$DEVENV_PATH"/logs/process-compose.log &
    wait $!
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
