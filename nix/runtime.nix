# Emulators and guest root, with launch/ files consumed by both launchers.
# launch/*-args: one argument per line; launch/env: NAME=value per line.
# launch/module and http-module select the emulator for each HTTP grant.
# launch/engine-version records the embedded Wasmtime version.
# Each VM must run on a private, writable copy of root/.
{ lib, stdenvNoCC, jq, wasm-tools, elixir, otp, guestDeps, licenseSources, manifest, launcher }:
let
  launchFiles = {
    # The emulator is a WASIp3 component whose threads are component-model
    # threads (cooperative, sharing one guest execution thread).
    # Emulator flags, written with "-" (beam is started directly, not through
    # erl, which would rewrite "+"). Helper threads are Wasm threads too: keep
    # them few and never let them busy-wait, which would burn host CPU while
    # idle. -fnu: Unicode file names (WASI paths are UTF-8). -Mea min: plain
    # malloc instead of ERTS's allocators; without mmap their carriers are
    # aligned allocations from wasi-libc's malloc, which fragment Wasm memory
    # (it never shrinks) until a guest that keeps building large heaps runs
    # out of memory with little live data.
    emulator-args = [
      "-SDcpu"
      "1:1"
      "-SDio"
      "1"
      "-A"
      "1"
      "-sbwt"
      "none"
      "-sbwtdcpu"
      "none"
      "-sbwtdio"
      "none"
      "-fnu"
      "-Mea"
      "min"
    ];
    init-args = [ "-root" "/" "-bindir" "/bin" "-progname" "erl" "-home" "/home" "-boot" "/bin/vm" "-noshell" ];
    env = [
      "HOME=/home"
      "USER=guest"
      "BINDIR=/bin"
      "EMU=beam"
      "LANG=C.UTF-8"
      "KETTLECORN_CACERTFILE=/etc/ssl/cert.pem"
    ];
    # Only the HTTP emulator imports wasi:http.
    module = [ "beam.wasm" ];
    http-module = [ "beam-http.wasm" ];
    engine-version = [ manifest.tested_with.wasmtime ];
  };
in
stdenvNoCC.mkDerivation {
  pname = "kettlecorn-runtime";
  version = manifest.kettlecorn;
  src = ../guest;
  nativeBuildInputs = [ elixir jq wasm-tools ];
  env.LANG = "C.UTF-8";

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    root=$PWD/root
    mkdir -p $root/bin $root/lib $root/home $root/tmp $root/work
    cp ${otp}/bin/vm.boot $root/bin/
    cp -R ${otp}/lib/. $root/lib/
    for app in elixir logger iex eex ex_unit; do
      mkdir -p $root/lib/$app
      cp -R ${elixir}/lib/elixir/lib/$app/ebin $root/lib/$app/
    done
    cp -R ${guestDeps}/. $root/lib/
    chmod -R u+w $root

    # The guest app, compiled with Req on the code path so that its Req
    # adapter (Kettlecorn.HTTP.ReqAdapter) is included.
    pa=()
    for app in ${guestDeps}/*; do pa+=(-pa $app/ebin); done
    elixirc "''${pa[@]}" -o $root/lib/kettlecorn_guest/ebin $(find lib -name '*.ex')
    substitute kettlecorn_guest.app.src $root/lib/kettlecorn_guest/ebin/kettlecorn_guest.app \
      --replace-fail '@VERSION@' ${lib.escapeShellArg manifest.kettlecorn}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    mkdir -p $out/bin
    cp ${lib.getExe launcher} $out/bin/kettlecorn-launch
    install -m755 ${../bin/kettlecorn-run} $out/bin/kettlecorn-run
    mkdir -p $out/licenses
    cp -R ${launcher}/share/licenses/kettlecorn-launcher $out/licenses/launcher
    cp ${otp}/beam.wasm ${otp}/beam-http.wasm $out/
    cp -R root $out/
    # Record required host interfaces in the manifest.
    imports() {
      wasm-tools component wit "$1" | sed -n 's/^ *import \(.*\);$/\1/p' | sort -u | jq -R . | jq -s .
    }
    jq --argjson beam "$(imports $out/beam.wasm)" --argjson http "$(imports $out/beam-http.wasm)" \
      '. + {imports: {"beam.wasm": $beam, "beam-http.wasm": $http}}' \
      ${builtins.toFile "manifest.json" (builtins.toJSON manifest)} > $out/manifest.json

    cp $out/manifest.json $out/root/manifest.json
    mkdir -p $out/launch
    ${lib.concatStrings (lib.mapAttrsToList (name: args: ''
      printf '%s\n' ${lib.escapeShellArgs args} > $out/launch/${name}
    '') launchFiles)}
    # The code path: every application in the root. A cooked app's own
    # applications are added by Kettlecorn.Boot.
    # ERL_LIBS=/lib can hang framed VM boot with networking; the cause is unresolved.
    for dir in $out/root/lib/*/; do
      printf '%s\n' -pa "/lib/$(basename "$dir")/ebin" >> $out/launch/init-args
    done

    ${lib.concatStrings (lib.mapAttrsToList (name: srcs: ''
      mkdir -p $out/licenses/${name}
      ${lib.concatStrings (lib.mapAttrsToList (file: src: ''
        cp -RL ${lib.escapeShellArg "${src}"} $out/licenses/${name}/${lib.escapeShellArg file}
      '') srcs)}
    '') licenseSources)}
    for dep in ${guestDeps.mixFodDeps}/*/; do
      app=$(basename $dep)
      mkdir -p $out/licenses/$app
      for f in $dep/LICENSE* $dep/NOTICE*; do
        if [ -e "$f" ]; then cp -L "$f" $out/licenses/$app/; fi
      done
      # A package without a license file: its Hex metadata names the license.
      [ -n "$(ls $out/licenses/$app)" ] || cp $dep/hex_metadata.config $out/licenses/$app/
    done
    runHook postInstall
  '';
}
