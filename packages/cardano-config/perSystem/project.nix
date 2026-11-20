{ inputs, ... }:

{
  perSystem = { pkgs, lib, ... }:
    let
      project = pkgs.haskell-nix.cabalProject' ({ config, pkgs, ... }: {
        src = ./..;
        name = "cardano-config";
        compiler-nix-name = lib.mkDefault "ghc967";

        inputMap = {
          "https://chap.intersectmbo.org/" = inputs.CHaP;
        };

        modules = [{
          packages.cardano-config.ghcOptions = [ "-Werror" "-fno-ignore-asserts" ];
          packages.cardano-crypto-praos.components.library.pkgconfig = lib.mkForce [ [ pkgs.libsodium-vrf ] ];
          packages.cardano-crypto-class.components.library.pkgconfig = lib.mkForce [ [ pkgs.libsodium-vrf pkgs.secp256k1 pkgs.libblst ] ];
        }];
      });
    in
    {
      _module.args.hsPkgs = project.hsPkgs;
      _module.args.shellFor = args: project.shellFor args;
      legacyPackages.project = project;
    };
}
