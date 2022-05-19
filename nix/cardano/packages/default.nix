{ inputs
, cell
,
}:
let
  inherit (inputs) self std nixpkgs iohkNix cardano-node
    cardano-wallet cardano-db-sync cardano-ogmios;
  inherit (inputs.cells) cardano;
  inherit (nixpkgs) lib;

  inherit (import inputs.nixpkgs-haskell {
    inherit (nixpkgs) system;
    inherit (inputs.haskellNix) config;
    overlays = with iohkNix.overlays; [
      inputs.haskellNix.overlay
      haskell-nix-extra
      crypto
      (final: prev: {
        haskellBuildUtils = prev.haskellBuildUtils.override {
          inherit compiler-nix-name index-state;
        };
      })
    ];
  }) haskell-nix;

  inherit (haskell-nix) haskellLib;

  project = with haskellLib.projectOverlays;
    (import ./haskell.nix {
      inherit haskell-nix;
      inherit (inputs) byron-chain;
      # TODO: switch to self after mono-repo branch is merged:
      src = cardano-node;
    }).appendOverlays [
      devshell
      projectComponents
      (final: prev: {
        release = nixpkgs.callPackage ./binary-release.nix {
          inherit (final.pkgs) stdenv;
          exes = lib.attrValues final.exes ++ [
            final.hsPkgs.bech32.components.exes.bech32
          ];
          inherit (final.exes.cardano-node.identifier) version;
          inherit (cardano.library) copyEnvsTemplate;
          inherit (cardano) environments;
        };
        profiled = final.appendModule {
          modules = [{
            enableLibraryProfiling = true;
            packages.cardano-node.components.exes.cardano-node.enableProfiling = true;
            packages.tx-generator.components.exes.tx-generator.enableProfiling = true;
            packages.locli.components.exes.locli.enableProfiling = true;
          }];
        };
        asserted = final.appendModule {
          modules = [{
            packages = lib.genAttrs [
              "ouroboros-consensus"
              "ouroboros-consensus-cardano"
              "ouroboros-consensus-byron"
              "ouroboros-consensus-shelley"
              "ouroboros-consensus-mock"
              "ouroboros-network"
              "network-mux"
              "io-classes"
              "strict-stm"
            ]
              (name: { flags.asserts = true; });
          }];
        };
        eventlogged = final.appendModule
          {
            modules = [{
              packages = lib.genAttrs [ "cardano-node" ]
                (name: { configureFlags = [ "--ghc-option=-eventlog" ]; });
            }];
          };
        hsPkgs = lib.mapAttrsRecursiveCond (v: !(lib.isDerivation v))
          (path: value:
            if (lib.isAttrs value) then
              lib.recursiveUpdate
                (if lib.elemAt path 2 == "exes" && lib.elem (lib.elemAt path 3) [ "cardano-node" "cardano-cli" ] then
                  let
                    # setGitRev is a script to stamp executables with version info.
                    # Done here to avoid tests depending on rev.
                    setGitRev = ''${final.pkgs.buildPackages.haskellBuildUtils}/bin/set-git-rev "${cardano-node.rev}" $out/bin/*'';
                  in
                  nixpkgs.runCommand value.name
                    {
                      inherit (value) exeName exePath meta passthru;
                    } ''
                    mkdir -p $out
                    cp --no-preserve=timestamps --recursive ${value}/* $out/
                    chmod -R +w $out/bin
                    ${setGitRev}
                  ''
                else value)
                {
                  passthru = {
                    profiled = lib.getAttrFromPath path final.profiled.hsPkgs;
                    asserted = lib.getAttrFromPath path final.asserted.hsPkgs;
                    eventlogged = lib.getAttrFromPath path final.eventlogged.hsPkgs;
                  };
                } else value)
          prev.hsPkgs;
      })
    ];

  inherit (project.args) compiler-nix-name;
  inherit (project) index-state;

in
project.exesFrom ./packages-exes.nix // {
  inherit project;
  inherit (project.appendModule { packagesExes = { }; }) generatePackagesExesMat;
  inherit (project.hsPkgs.bech32.components.exes) bech32;
  inherit (cardano-wallet.packages) cardano-wallet;
  inherit (cardano-wallet.packages) cardano-address;
  inherit (cardano-db-sync.packages) cardano-db-sync;
  inherit (cardano-ogmios.packages) ogmios;
  cardano-config-html-public =
    let
      publicEnvNames = [ "mainnet" "testnet" "vasil-qa" "vasil-dev" ];
      environments = lib.filterAttrs (n: _: builtins.elem n publicEnvNames) cardano.environments;
    in
    cardano.library.generateStaticHTMLConfigs environments;
  cardano-config-html-internal = cardano.library.generateStaticHTMLConfigs cardano.environments;
}
