{
  description = "Kettlecorn: sandboxed Elixir on OTP compiled to WASI (wasm32-wasip3), run by an embedded Wasmtime launcher";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Popcorn (Software Mansion): its OTP patch stack. Tracks main; the commit
    # is pinned in flake.lock (`just update-popcorn`).
    popcorn = {
      url = "github:software-mansion/popcorn";
      flake = false;
    };
    # Erlang/OTP for the guest. Its major release must be the host Erlang's
    # (nixpkgs' beamMinimal29Packages; the build checks).
    otp = {
      url = "github:erlang/otp/OTP-29.1.2";
      flake = false;
    };
    # Elixir, for the guest and the host side alike: built with nixpkgs'
    # Elixir 1.20 builder from this tag (`just update-elixir`).
    elixir = {
      url = "github:elixir-lang/elixir/v1.20.5";
      flake = false;
    };
    # wasi-libc with cooperative-thread (component-model threading) support.
    wasi-libc = {
      url = "github:WebAssembly/wasi-libc/c3a02dcd35cc0048a5ab6a30142b2df6349947ef";
      flake = false;
    };
  };

  # Nix must trust these settings to use the cache; pass --accept-flake-config.
  nixConfig = {
    extra-substituters = [ "https://kettlecorn.cachix.org" ];
    extra-trusted-public-keys = [ "kettlecorn.cachix.org-1:6Tw22UEqmvYwoL3jUrBlmhNoouT73qpmftfrzbJLnQw=" ];
  };

  outputs = { self, nixpkgs, flake-utils, popcorn, otp, elixir, wasi-libc }:
    # nixpkgs no longer builds for x86_64-darwin; macOS is aarch64-darwin.
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # Host tools also compile guest .beam files: match the guest's OTP
        # major release and exact Elixir version.
        elixirVersion = lib.fileContents "${elixir}/VERSION";
        beamPackages = pkgs.beamMinimal29Packages.overrideScope (final: prev: {
          elixir =
            assert lib.assertMsg (lib.versions.majorMinor elixirVersion == "1.20")
              "Elixir ${elixirVersion}: switch elixir_1_20 in flake.nix to its builder";
            prev.elixir_1_20.overrideAttrs (_: {
              version = elixirVersion;
              # The input's tree, as a fixed-output fetch: for the version
              # nixpkgs has, the derivation is nixpkgs' own (binary cache).
              src = pkgs.fetchFromGitHub {
                owner = "elixir-lang";
                repo = "elixir";
                inherit (elixir) rev;
                hash = elixir.narHash;
              };
            });
        });
        inherit (beamPackages) erlang;
        elixirPkg = beamPackages.elixir;
        wasmtime = pkgs.wasmtime;
        launcherPackages = if pkgs.stdenv.isLinux then pkgs.pkgsStatic else pkgs;
        launcher = launcherPackages.callPackage ./nix/launcher.nix {
          wasmtimeVersion = wasmtime.version;
        };

        toolchain = pkgs.callPackage ./nix/toolchain.nix {
          inherit wasmtime;
          wasi-libc-src = wasi-libc;
        };
        openssl = pkgs.callPackage ./nix/openssl.nix { inherit toolchain; };
        otpWasi = pkgs.callPackage ./nix/otp.nix {
          inherit erlang toolchain openssl;
          otp-src = otp;
          popcorn-src = popcorn;
        };
        basePackages = with pkgs; [
          git
          just
          curl
          nixpkgs-fmt
          erlang
          elixirPkg
          wasmtime
          python3
          rustc
          cargo
          rustfmt
          clippy
        ];

        devPackages = [
          beamPackages.elixir-ls
          pkgs.cachix
        ];

        env = {
          LANG = "C.UTF-8";
          ERL_AFLAGS = "-kernel shell_history enabled";
        };

        shellHook = ''
          # Keep Mix/Hex state inside the project, so it matches this shell's
          # Elixir and OTP. `just deps` installs Hex.
          export MIX_HOME=$PWD/.nix-mix
          export HEX_HOME=$PWD/.nix-hex
          export PATH="$MIX_HOME/bin:$MIX_HOME/escripts:$PATH"
        '';

      in
      {
        packages = {
          default = otpWasi;
          inherit openssl launcher;
          otp = otpWasi;
          inherit (toolchain) resourceDir sysroot compat cc;
        };

        checks.otp = otpWasi;

        checks.stdio = pkgs.runCommand "kettlecorn-stdio-tests"
          { nativeBuildInputs = [ pkgs.stdenv.cc pkgs.python3 erlang ]; }
          ''
            export HOME=$TMPDIR
            python3 ${./c}/test/stdio_test.py
            touch $out
          '';

        devShells = {
          ci = pkgs.mkShell {
            packages = basePackages;
            inherit env shellHook;
          };

          default = pkgs.mkShell {
            packages = basePackages ++ devPackages
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux
              (with pkgs; [ inotify-tools libnotify ])
              ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ pkgs.terminal-notifier ];

            inherit env shellHook;
          };

        };
      });
}
