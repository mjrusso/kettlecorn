# Runtime archives contain a native launcher. Keep archive metadata reproducible.
{ runCommand, runtime, version, system }:
let
  name = "kettlecorn-runtime-${version}-${system}";
in
runCommand "${name}-release" { } ''
  mkdir -p ${name}/bin
  cp -R ${runtime}/. ${name}/
  chmod -R u+w ${name}
  # Restore the portable shebang after the Nix runtime's fixup phase.
  cp ${../bin/kettlecorn-run} ${name}/bin/kettlecorn-run
  chmod 755 ${name}/bin/kettlecorn-run
  cat > ${name}/README.md <<'EOF'
  # Kettlecorn runtime ${version}

  This archive contains a BEAM emulator compiled to WebAssembly (WASIp3)
  and a guest file system with OTP and Elixir, plus a native launcher for
  ${system}. Python and the Wasmtime CLI are not required.

      bin/kettlecorn-run script.exs       # like `elixir script.exs`
      bin/kettlecorn-run --iex            # like `iex`
      bin/kettlecorn-run --help

  From Elixir, use the `kettlecorn` Hex package (`mix kettlecorn.install`
  downloads this archive). `manifest.json` records component versions.
  `licenses/` contains their licenses.
  EOF
  mkdir -p $out
  tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -c ${name} \
    | gzip -9n > $out/${name}.tar.gz
  (cd $out && sha256sum ${name}.tar.gz > ${name}.tar.gz.sha256)
''
