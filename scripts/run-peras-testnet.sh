#!/usr/bin/env bash

set -e


cabal build cardano-node-chairman cardano-testnet cardano-cli cardano-node cardano-tracer peras-testnet

cleanup() {
    trap - EXIT INT TERM
    kill -- -$$ 2>/dev/null || true
}
trap cleanup EXIT INT TERM

CARDANO_NODE=$(cabal list-bin cardano-node)
CARDANO_NODE_CHAIRMAN=$(cabal list-bin cardano-node-chairman)
CARDANO_CLI=$(cabal list-bin cardano-cli)
CARDANO_TESTNET=$(cabal list-bin cardano-testnet)
CARDANO_TRACER=$(cabal list-bin cardano-tracer:cardano-tracer)
CARDANO_PERAS_TESTNET=$(cabal list-bin peras-testnet)

export CARDANO_NODE CARDANO_NODE_CHAIRMAN CARDANO_CLI CARDANO_TESTNET CARDANO_TRACER CARDANO_PERAS_TESTNET

TESTNET_SCENARIOS_DIR="${TESTNET_SCENARIOS_DIR:-packages/peras-testnet/scenarios}"

usage() {
    echo "Usage: $0 [SCENARIO]" >&2
    echo "  SCENARIO defaults to 'vanilla' if omitted." >&2
    echo "Available scenarios:" >&2
    for f in "$TESTNET_SCENARIOS_DIR"/*.yaml; do
        [ -e "$f" ] && echo "  $(basename "$f" .yaml)" >&2
    done
}

runTestnet() {
    scenarioArg="${1:-vanilla}"
    scenarioFile="$scenarioArg"
    if [ ! -f "$scenarioArg" ]; then
      scenarioFile="$TESTNET_SCENARIOS_DIR/$scenarioArg.yaml"
      if [ ! -f "$scenarioFile" ]; then
          echo "Unknown scenario '$scenarioArg': $scenarioFile does not exist." >&2
          usage
          exit 1
      fi
    fi
    echo "Using scenario: $scenarioFile"
    export TESTNET_SCENARIO="$scenarioFile"
    process-compose \
        -f <("$CARDANO_PERAS_TESTNET" stdout-compose-yaml "$CARDANO_PERAS_TESTNET") \
        -p 3030 \
        -L process-compose.log
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
