{
  perSystem = { hsPkgs, ... }:
    let
      cc = hsPkgs.cardano-config;
    in
    {
      packages.cardano-config     = cc.components.library;
      packages.cardano-config-exe = cc.components.exes.cardano-config;

      checks.cardano-config-test  = cc.checks.cardano-config-test;
    };
}
