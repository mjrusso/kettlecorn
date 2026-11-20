{ lib, stdenv, rustPlatform, libiconv, darwin, cctools, release }:
let
  project = "examples/rust/device-monitor";
  cargo = builtins.fromTOML (builtins.readFile ../examples/rust/device-monitor/Cargo.toml);
in
rustPlatform.buildRustPackage {
  pname = cargo.package.name;
  inherit (cargo.package) version;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../examples/rust/device-monitor/Cargo.lock
      ../examples/rust/device-monitor/Cargo.toml
      ../examples/rust/device-monitor/src
      ../rust/Cargo.toml
      ../rust/build.rs
      ../rust/src
    ];
  };
  cargoRoot = project;
  buildAndTestSubdir = project;
  cargoLock.lockFile = ../examples/rust/device-monitor/Cargo.lock;
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isDarwin [
    cctools
    darwin.autoSignDarwinBinariesHook
  ];
  doCheck = false;

  postInstall = lib.optionalString stdenv.hostPlatform.isDarwin ''
    install_name_tool -change ${lib.getLib libiconv}/lib/libiconv.2.dylib \
      /usr/lib/libiconv.2.dylib "$out/bin/device-monitor"
  '';

  # Extract after fixup to preserve the archive's kettlecorn-run shebang.
  postFixup = ''
    cp -R ${../examples/rust/device-monitor/plugins} "$out/plugins"
    cp ${../examples/rust/device-monitor/telemetry.jsonl} "$out/telemetry.jsonl"
    mkdir "$out/runtime"
    tar -xzf ${release}/*.tar.gz --strip-components=1 -C "$out/runtime"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    bundle="$TMPDIR/copied bundle"
    cp -R "$out" "$bundle"
    program="$bundle/bin/device-monitor"
    mkdir "$TMPDIR/run" "$TMPDIR/home" "$TMPDIR/scratch"
    cd "$TMPDIR/run"
    cp -R "$bundle/plugins" "custom plugins"

    env -i PATH= HOME="$TMPDIR/home" TMPDIR="$TMPDIR/scratch" \
      "$program" "$bundle/telemetry.jsonl" \
      "custom plugins/sustained_heat.exs" "custom plugins/rapid_rise.exs" > actual.jsonl 2> diagnostics.log
    diff -u ${../examples/rust/device-monitor/expected.jsonl} actual.jsonl
    grep -Fx 'sustained_heat: restarted worker for north' diagnostics.log
    test -z "$(ls -A "$TMPDIR/scratch")"
  '' + lib.optionalString stdenv.hostPlatform.isDarwin ''
    otool -L "$program" > libs.txt
    if grep -F /nix/store/ libs.txt; then exit 1; fi
  '' + lib.optionalString stdenv.hostPlatform.isLinux ''
    ${stdenv.cc.bintools}/bin/${stdenv.cc.bintools.targetPrefix}readelf -l "$program" > headers.txt
    if grep -w INTERP headers.txt; then exit 1; fi
  '' + ''
    runHook postInstallCheck
  '';

  meta.mainProgram = "device-monitor";
}
