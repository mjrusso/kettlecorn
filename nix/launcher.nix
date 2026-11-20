{ lib, stdenv, rustPlatform, pkg-config, cmake, perl, libiconv, darwin }:
let
  cargo = builtins.fromTOML (builtins.readFile ../rust/Cargo.toml);
in
assert lib.all (name: cargo.dependencies.${name}.version == cargo.dependencies.wasmtime.version)
  [ "wasmtime-wasi" "wasmtime-wasi-http" ];
rustPlatform.buildRustPackage {
  pname = "kettlecorn-launcher";
  version = cargo.package.version;
  src = lib.cleanSource ../rust;
  cargoLock.lockFile = ../rust/Cargo.lock;
  nativeBuildInputs = [ pkg-config cmake perl ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [ darwin.autoSignDarwinBinariesHook ];
  buildFeatures = [ "cli" ];
  doCheck = true;
  cargoTestFlags = [ "--lib" ];
  postInstall = ''
    mkdir -p $out/share/licenses/kettlecorn-launcher
    for crate in $cargoDeps/*; do
      [ -d "$crate" ] || continue
      dest=$out/share/licenses/kettlecorn-launcher/$(basename "$crate")
      mkdir -p "$dest"
      find -L "$crate" -maxdepth 2 -type f \( -iname 'license*' -o -iname 'copying*' -o -iname 'notice*' -o -iname 'copyright*' \) -exec cp --backup=numbered '{}' "$dest/" \;
      [ -n "$(ls -A "$dest")" ] || cp "$crate/Cargo.toml" "$dest/"
    done
  '' + lib.optionalString stdenv.hostPlatform.isDarwin ''
    install_name_tool -change ${lib.getLib libiconv}/lib/libiconv.2.dylib \
      /usr/lib/libiconv.2.dylib $out/bin/kettlecorn-launch
  '';
  meta.mainProgram = "kettlecorn-launch";
}
