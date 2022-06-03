{ inputs
, cell
,
}:
let
  inherit (inputs) nixpkgs cells;
  inherit (nixpkgs) lib;
  inherit (nixpkgs.stdenv) hostPlatform;
  inherit (cell) devshells;
  inherit (cell.jobs) mkHydraRequiredJob;
  jobs = {
    inherit devshells;
  };
  nonRequiredPaths = map lib.hasPrefix [ ];
  required = mkHydraRequiredJob nonRequiredPaths jobs;
in
jobs // {
  inherit required;
}
