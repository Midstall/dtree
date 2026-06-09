{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      nameValuePair = name: value: { inherit name value; };
      genAttrs = names: f: builtins.listToAttrs (map (n: nameValuePair n (f n)) names);
      allSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems =
        f:
        genAttrs allSystems (
          system:
          f {
            inherit system;
            pkgs = import nixpkgs { inherit system; };
          }
        );

      treefmtEval = forAllSystems ({ pkgs, ... }: treefmt-nix.lib.evalModule pkgs (import ./treefmt.nix));
    in
    {
      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            name = "dtree-dev-shell";
            packages = with pkgs; [
              zig
            ];
          };
        }
      );

      formatter = forAllSystems ({ system, ... }: treefmtEval.${system}.config.build.wrapper);
    };
}
