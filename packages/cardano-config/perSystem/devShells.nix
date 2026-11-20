{ inputs, ... }: {
  perSystem = { shellFor, pkgs, ... }: {
    devShells.default = shellFor {
      packages = p: [ p.cardano-config ];

      nativeBuildInputs = [
        pkgs.jq
        pkgs.gh
      ];

      tools = {
        cabal = "latest";
        ghcid = "latest";
        haskell-language-server = {
          src = inputs.haskellNix.inputs."hls-2.10";
          configureArgs = "--disable-benchmarks --disable-tests";
        };
      };

      shellHook = ''
        export LANG="en_US.UTF-8"
      '';

      # Building the in-shell Hoogle index forces haddock generation for every
      # transitive dependency (see haskell.nix builder/shell-for.nix), which was
      # failing on Hydra. Disable it so dependency haddocks are not built.
      withHoogle = false;
    };
  };
}
