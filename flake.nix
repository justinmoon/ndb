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
        inherit (pkgs) lib stdenv;
        zigPkg = zig.packages.${system}."0.15.1";
        devInputs = with pkgs; [
          zigPkg
          pkg-config
          lmdb
          secp256k1
          gnumake
          cmake
          git
        ] ++ lib.optionals stdenv.isLinux [
          gcc
        ] ++ lib.optionals stdenv.isDarwin [
          clang
        ];
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = devInputs;
          shellHook = ''
            export ZIG_GLOBAL_CACHE_DIR=$(pwd)/.zig-cache
            export ZIG_LOCAL_CACHE_DIR=$ZIG_GLOBAL_CACHE_DIR
            export PATH="${zigPkg}/bin:$PATH"
            if [ -n "''${NIX_CFLAGS_COMPILE-}" ]; then
              filtered_flags=""
              for flag in $NIX_CFLAGS_COMPILE; do
                case "$flag" in
                  -fmacro-prefix-map=*) ;;
                  *) filtered_flags="$filtered_flags $flag" ;;
                esac
              done
              NIX_CFLAGS_COMPILE="''${filtered_flags# }"
              export NIX_CFLAGS_COMPILE
            fi
            git submodule update --init --recursive
            echo "nostrdb-zig with Zig ${zigPkg.version}"
          '';
        };
      }
    );
}
