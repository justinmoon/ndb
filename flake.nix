{
  description = "Lightweight Zig wrapper around the nostrdb C library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zigPkg = zig.packages.${system}."0.12.1";
        baseInputs = with pkgs; [
          zigPkg
          git
          pkg-config
        ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
          clang
        ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
          gcc
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = baseInputs;
          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR=$(pwd)/.zig-cache
            export ZIG_LOCAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR
            echo "nostrdb-zig dev shell"
            echo "Commands:"
            echo "  zig build         # build static library"
            echo "  zig build test    # run wrapper tests"
          '';
        };

        apps.test = {
          type = "app";
          program = pkgs.writeShellApplication {
            name = "run-nostrdb-zig-tests";
            runtimeInputs = baseInputs;
            text = ''
              set -euo pipefail
              git submodule update --init --recursive
              zig build test
            '';
          };
        };
      }
    );
}
