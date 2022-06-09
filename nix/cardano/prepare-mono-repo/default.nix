{ inputs
, cell
,
}:
let
  inherit (inputs) nixpkgs cardano-node;
  inherit (nixpkgs) lib;
  inherit (cell.packages) project;

  mono-repo =
    let
      node =
        nixpkgs.fetchFromGitHub {
          owner = "input-output-hk";
          repo = "cardano-node";
          inherit (cardano-node) rev;
          sha256 = lib.fileContents ./cardano-node.sha256;
          deepClone = true;
          leaveDotGit = true;
        };
      nodeProject = project.appendModule {
        src = lib.mkForce node;
      };
      ouroboros = nixpkgs.fetchFromGitHub {
        owner = "input-output-hk";
        repo = "ouroboros-network";
        rev = nodeProject.pkg-set.config.packages.ouroboros-network.src.rev;
        sha256 = lib.fileContents ./ouroboros-network.sha256;
        deepClone = true;
        leaveDotGit = true;
      };
      ouroborosProject = project.appendModule {
        src = lib.mkForce ouroboros;
      };
      ledger = nixpkgs.fetchFromGitHub {
        owner = "input-output-hk";
        repo = "cardano-ledger";
        rev = nodeProject.pkg-set.config.packages.cardano-ledger-core.src.rev;
        sha256 = lib.fileContents ./cardano-ledger.sha256;
        deepClone = true;
        leaveDotGit = true;
      };
      ledgerProject = project.appendModule {
        src = lib.mkForce ledger;
      };
      ekgforward = nixpkgs.fetchFromGitHub {
        owner = "input-output-hk";
        repo = "ekg-forward";
        rev = nodeProject.pkg-set.config.packages.ekg-forward.src.rev;
        sha256 = lib.fileContents ./ekg-forward.sha256;
        deepClone = true;
        leaveDotGit = true;
      };
      packagePaths = project: lib.concatStringsSep " " (lib.mapAttrsToList (_: p: let subdir = lib.removePrefix "/" p.src.origSubDir; in "--path-rename ${subdir}:src/${subdir} --path ${subdir}") project.packages);
      cabalProject = builtins.toFile "cabal.project" (import ./cabal.project.nix {
        inherit lib;
        inherit (nodeProject) index-state;
        packages = lib.attrValues (nodeProject.packages // ouroborosProject.packages // ledgerProject.packages // {
          ekg-forward = {
            identifier.name = "ekg-forward";
            src.origSubDir = "/ekg-forward";
          };
        });
        cardano-base-src = nodeProject.pkg-set.config.packages.cardano-binary.src;
        plutus-src = nodeProject.pkg-set.config.packages.plutus-core.src;
      });
    in
    nixpkgs.runCommand "mono-repo"
      {
        inherit (inputs.self) rev;
        nativeBuildInputs = with nixpkgs; [ git-filter-repo git nix ];
      } ''
      export HOME="$(pwd)"
      git config --global user.email "jean-baptiste.giraudeau@iohk.io"
      git config --global user.name "Jean-Baptiste Giraudeau"

      cp -r ${node} $out

      cp -r ${ouroboros} ouroboros;
      cd ouroboros
      ouroboros_repo="$(pwd)"
      chmod -R +w .
      git-filter-repo --force --path-rename docs:docs/network --path docs ${packagePaths ouroborosProject}
      git filter-repo --force --path-glob '*.nix' --invert-paths

      cd ..

      cp -r ${ledger} ledger;
      cd ledger
      ledger_repo="$(pwd)"
      chmod -R +w .
      git-filter-repo --force --path-rename doc:docs/ledger --path-rename docs:docs/ledger --path docs --path doc ${packagePaths ledgerProject}
      git filter-repo --force --path-glob '*.nix' --path-glob '*/.ghcid' --path-glob '*/.gitignore' --invert-paths

      cd ..

      cp -r ${ekgforward} ekgforward;
      cd ekgforward
      ekgforward_repo="$(pwd)"
      chmod -R +w .
      git-filter-repo --force --path demo --path src --path test --path ekg-forward.cabal --path README.md --path CHANGELOG.md --path LICENSE
      git-filter-repo --to-subdirectory-filter src/ekg-forward

      cd ..

      cd $out
      ls -la
      chmod -R +w .
      git-filter-repo --force --path cabal.project --path-rename doc:docs/node --path doc ${packagePaths nodeProject}
      git clean -fxd

      git remote add ouroboros $ouroboros_repo
      git fetch ouroboros
      git merge ouroboros/fetchgit --allow-unrelated-histories --no-ff

      git remote add ledger $ledger_repo
      git fetch ledger
      git merge ledger/fetchgit --allow-unrelated-histories --no-ff

      git remote add ekgforward $ekgforward_repo
      git fetch ekgforward
      git merge ekgforward/fetchgit --allow-unrelated-histories --no-ff

      cp ${cabalProject} cabal.project
      git apply ${./cabal.diff}
      git add .
      git commit -a -m "Adapt cabal build after merge into mono repo"
    '';
in
{
  inherit mono-repo;
}
