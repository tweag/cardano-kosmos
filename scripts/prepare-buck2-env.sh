#!/usr/bin/env bash

set -e

echo "Preparing buck2 setup"

if [ ! -d buck2 ]; then
  git clone --branch 0.5.0.0 https://github.com/simonmar/haskell-buck2 buck2
fi

if [ ! -d third-party ]; then
  cabal update
  cabal-buck2
fi

echo "
Now you can use buck2:
  - buck2 build root//packages/cardano-node/cardano-node:cardano-node-exe
  - buck2 build root//packages/ouroboros-consensus:diffusion
"
