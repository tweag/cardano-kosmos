#!/usr/bin/env bash

set -e

echo "Preparing buck2 setup"

if [ ! -d buck2 ]; then
  git clone --branch 0.5.0.0 https://github.com/simonmar/haskell-buck2 buck2
fi

if [ ! -d third-party ]; then
  cabal update
  cabal-buck2

  # Create local buck config to link zlib and set 01 otherwise cardano-node fails to start
  cat << EOF > .buckconfig.local
[haskell]
  compiler_flags = -O1
  linker_flags = -L$1/lib

[project]
  ignore = .git
EOF

  # Add zlib-c lib to BUCK
  cat << EOF >> third-party/haskell/BUCK
prebuilt_cxx_library(
    name = "zlib-c",
    exported_linker_flags = [
        "-L$1/lib",
        "-lz",
    ],
    header_only = True,
)
EOF

  # Add the usage of static zlib-c to haskell_prebuilt_library zlib
  sed -i "/name = 'zlib',/,/^)/ { /':bytestring',/a\        ':zlib-c',
}" third-party/haskell/BUCK
fi

echo "
Now you can use buck2:
  - buck2 build root//packages/cardano-node/cardano-node:cardano-node-exe
  - buck2 build root//packages/ouroboros-consensus:diffusion
"
