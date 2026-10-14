# Cardano Kosmos

This is a monorepository of Cardano libraries for the development of [Peras](https://github.com/tweag/cardano-peras/).

The `main` branch follows [cardano-node](https://github.com/IntersectMBO/cardano-node)'s `master`, never catching up with it like [Sisyphus](https://en.wikipedia.org/wiki/Sisyphus).

To start working, you simply need

```
nix develop
./scripts/run-peras-testnet.sh
```

That will build all necessary dependencies and start the Peras testnet process-compose.

To reconfigure the testnet or scenario params, change `nickel/scenarios/<scenario>.ncl` or `nickel/testnet.ncl` and reconfigure before run:

```
./scripts/setup-testnet-env.sh
./scripts/run-peras-testnet.sh
```
