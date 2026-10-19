{
  description = "Cardano Kosmos";

  nixConfig = {
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
  };

  inputs = {
    # Custom user config (default: empty), eg:
    # { outputs = {...}: {
    #   # Customize listening port of node scripts:
    #   nixosModules.cardano-node.services.cardano-node.port = 3002;
    # };
    customConfig.url = "github:input-output-hk/empty-flake";

    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages?ref=index-only";
      flake = false;
    };

    cardano-dev.url = "github:input-output-hk/cardano-dev";

    empty-flake.url = "github:input-output-hk/empty-flake";

    flake-compat = {
      url = "github:input-output-hk/flake-compat/fixes";
      flake = false;
    };

    hackageNix = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };

    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.hackage.follows = "hackageNix";
    };

    incl.url = "github:divnix/incl";

    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixpkgs.follows = "haskellNix/nixpkgs-unstable";

    freshNixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    cardano-dev,
    CHaP,
    haskellNix,
    incl,
    iohkNix,
    nixpkgs,
    self,
    utils,
    freshNixpkgs,
    ...
  } @ input: let
    inherit (builtins) elem match;
    inherit (nixpkgs) lib;
    inherit (lib) collect getAttr genAttrs filterAttrs hasPrefix head isDerivation mapAttrs optionalAttrs optional optionals recursiveUpdate;
    inherit (utils.lib) eachSystem flattenTree;
    inherit (iohkNix.lib) prefixNamesWith;
    removeRecurse = lib.filterAttrsRecursive (n: _: n != "recurseForDerivations");

    macOS-security = pkgs:
    # Make `/usr/bin/security` available in `PATH`, which is needed for stack
    # on darwin which calls this binary to find certificates
      pkgs.writeScriptBin "security" ''exec /usr/bin/security "$@"'';

    windowsCompilerNixName = "ghc9122";

    supportedSystems = import ./nix/supported-systems.nix;
    defaultSystem = head supportedSystems;
    customConfig =
      recursiveUpdate
      (import ./nix/custom-config.nix customConfig)
      input.customConfig;

    overlays = [
      # Crypto needs to come before haskell.nix.
      # FIXME: _THIS_IS_BAD_
      iohkNix.overlays.crypto
      haskellNix.overlay
      iohkNix.overlays.haskell-nix-extra
      iohkNix.overlays.haskell-nix-crypto
      iohkNix.overlays.cardano-lib
      iohkNix.overlays.utils
      (final: prev: {
        inherit customConfig;
        gitrev = final.customConfig.gitrev or self.rev or "0000000000000000000000000000000000000000";
        commonLib =
          lib
          // iohkNix.lib
          // final.cardanoLib
          // import ./nix/svclib.nix {inherit (final) pkgs;};
      })
      (final: prev: {
        # For musl builds, make sure the static `liburing.a` file is not deleted in `postInstall`
        # ex: https://github.com/NixOS/nixpkgs/blob/f84a9816b2d5f7caade4b2fab16a66486abb7038/pkgs/by-name/li/liburing/package.nix#L43-L45
        liburing = prev.liburing.overrideAttrs (attrs:
          final.lib.optionalAttrs final.stdenv.hostPlatform.isMusl {
            postInstall = builtins.replaceStrings ["rm $out/lib/liburing*.a"] [""] attrs.postInstall;
          });
      })
      (import ./nix/pkgs.nix)
      self.overlay
    ];

    collectExes = project: let
      set-git-rev = import ./nix/set-git-rev.nix {inherit (project) pkgs;};
    in
      # Take all executables from the project local packages
      project.exes
      // (with project.hsPkgs;
        {
          # Add some executables from other relevant packages
          inherit (bech32.components.exes) bech32;
          inherit (dmq-node.components.exes) dmq-node;
          inherit (ouroboros-consensus.components.exes) db-analyser db-synthesizer db-truncater snapshot-converter;
          inherit (kes-agent.components.exes) kes-agent kes-agent-control;
          # Add cardano-node, cardano-cli and tx-generator with their git revision stamp.
          # Keep available an alternative without the git revision, like the other
          # passthru (profiled and asserted in nix/haskell.nix) that
          # have no git revision but for the same compilation alternative.
          cardano-node = let
            node = project.exes.cardano-node;
          in
            recursiveUpdate
            (set-git-rev node)
            {passthru = {noGitRev = node;};};
          cardano-cli = let
            cli = cardano-cli.components.exes.cardano-cli;
          in
            recursiveUpdate
            (set-git-rev cli)
            {passthru = {noGitRev = cli;};};
          cardano-submit-api = let
            submit-api = project.exes.cardano-submit-api;
          in
            recursiveUpdate
            (set-git-rev submit-api)
            {passthru = {noGitRev = submit-api;};};
        });

    mkCardanoNodePackages = project:
      (collectExes project)
      // {
        inherit (project.pkgs) cardanoLib;
      };

    mkFlakeAttrs = pkgs: freshPkgs: rec {
      system = pkgs.stdenv.hostPlatform.system;
      inherit (pkgs.haskell-nix) haskellLib;
      inherit (pkgs.commonLib) eachEnv environments;
      inherit (pkgs.stdenv) hostPlatform;
      project = pkgs.cardanoNodeProject;

      macOS-security =
        utils.writeScriptBin "security" ''exec /usr/bin/security "$@"'';

      # This is used by `nix develop .` to open a devShell
      devShells = let
        shell = import ./shell.nix {inherit pkgs customConfig;};
        grafanaPlugins =
          freshPkgs.linkFarm "grafana-plugins"
          (map (p: {
            name = p.pname;
            path = p;
          }) (with freshPkgs.grafanaPlugins; [prometheus loki]));
        extendedShell = shell.dev.overrideAttrs (attrs: {
          GRAFANA_CORE_PLUGINS = grafanaPlugins;
          nativeBuildInputs = (attrs.nativeBuildInputs or []) ++ [
            pkgs.process-compose
            pkgs.curl
            pkgs.bash
            pkgs.git
            pkgs.which
            pkgs.xxd
            pkgs.jq
            pkgs.toxiproxy
            pkgs.gnused
            pkgs.moreutils
            pkgs.ripgrep
            pkgs.git-subrepo
            freshPkgs.victoriametrics
            freshPkgs.victorialogs
            freshPkgs.vlagent
            freshPkgs.grafana
            freshPkgs.nickel
          ];
        });
      in
        {
          default = extendedShell;
          with-buck2 = extendedShell.overrideAttrs (attrs: {
            tools = (attrs.tools or {}) // {
              cabal-buck2 = "0.3.0.0";
            };
          });
          profiled = project.profiled.shell;
        };

      projectExes = collectExes project;

      exes =
        projectExes
        // {
          inherit (pkgs) checkCabalProject;
        }
        // flattenTree (pkgs.scripts
          // {
            # `tests` are the test suites which have been built.
            inherit (project) tests;
            # `benchmarks` (only built, not run).
            inherit (project) benchmarks;
          });

      packages = exes;
    };

    flake = eachSystem supportedSystems (
      system: let
        inherit (haskellNix) config;
        pkgs = import nixpkgs {
          inherit config system overlays;
        };
        freshPkgs = import freshNixpkgs {
          inherit config system overlays;
        };
        inherit (mkFlakeAttrs pkgs freshPkgs) environments packages project devShells;
      in {
        inherit environments project devShells;
      }
    );
  in
    flake 
    // {
      # Allows precise paths (avoid fallbacks) with nix build/eval:
      outputs = self;

      overlay = final: prev: {
        cardanoNodeProject =
          (import ./nix/haskell.nix {
            inherit (final) haskell-nix;
            inherit CHaP incl windowsCompilerNixName;
            macOS-security = macOS-security (final.pkgs);
            # buildPlatform, not hostPlatform: herald is a developer tool that
            # runs on the machine, so cross shells (e.g. windows) must not try
            # to resolve it for a system cardano-dev does not build for.
            herald = cardano-dev.packages.${final.stdenv.buildPlatform.system}.herald;
          })
          .appendModule [
            customConfig.haskellNix
          ];
        cardanoNodePackages = mkCardanoNodePackages final.cardanoNodeProject;
        inherit
          (final.cardanoNodePackages)
          bech32
          cardano-cli
          cardano-node
          cardano-submit-api
          cardano-tracer
          db-analyser
          db-synthesizer
          db-truncater
          dmq-node
          locli
          snapshot-converter
          tx-generator
          ;
      };
    };
}
