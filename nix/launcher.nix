{ lib, rustPlatform, pkg-config, cmake, perl, wasmtimeVersion }:
let
  cargo = builtins.fromTOML (builtins.readFile ../launcher/Cargo.toml);
in
assert cargo.package.metadata.kettlecorn.wasmtime == wasmtimeVersion;
assert lib.all (name: cargo.dependencies.${name}.version == "=${wasmtimeVersion}")
  [ "wasmtime" "wasmtime-wasi" "wasmtime-wasi-http" ];
rustPlatform.buildRustPackage {
  pname = "kettlecorn-launcher";
  version = cargo.package.version;
  src = lib.cleanSource ../launcher;
  cargoLock.lockFile = ../launcher/Cargo.lock;
  nativeBuildInputs = [ pkg-config cmake perl ];
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
  '';
  meta.mainProgram = "kettlecorn-launch";
}
