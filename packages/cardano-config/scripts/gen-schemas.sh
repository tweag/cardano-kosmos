#!/usr/bin/env bash
# Regenerate the committed JSON schemas under schemas/ from the codecs.
#
# Run from the cardano-config package directory. The schema-drift test
# (cabal test cardano-config-test) checks these files stay in sync.
set -euo pipefail

cd "$(dirname "$0")/.."

run() { cabal run -v0 cardano-config -- schema "$@"; }

mkdir -p schemas
run > schemas/config.schema.json

echo "Wrote schemas/config.schema.json."
