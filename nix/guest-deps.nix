# Hex packages for the guest (Req and its dependencies, see guest/hex/mix.exs),
# fetched from mix.lock and compiled with the host Elixir: .beam files are
# portable, so they run unchanged in the wasm VM. Produces $out/<app>/ebin.
{ beamPackages }:
let
  pname = "kettlecorn-guest-deps";
  version = "unversioned";
  src = ../guest/hex;
in
beamPackages.mixRelease {
  inherit pname version src;
  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-src";
    inherit version src;
    # `just update-guest-deps` refreshes this after mix.lock changes.
    hash = "sha256-RNw5qKEEh1ATZM1fCkuvKpJOyoO5yj1casbC67TRS/k=";
  };
  removeCookie = false;
  # This output has no release scripts for the builder to wrap.
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    for dir in _build/prod/lib/*; do
      app=$(basename $dir)
      [[ $app == kettlecorn_guest_deps || $app == hex ]] && continue
      mkdir -p $out/$app
      cp -R $dir/ebin $out/$app/
    done
    runHook postInstall
  '';
}
