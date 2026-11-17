# fetchMixDeps uses host/mix.lock for test dependencies; dev-only check
# tools aren't fetched.
{ lib, stdenv, beamPackages, procps, runtime }:
let
  pname = "kettlecorn-host-tests";
  version = "unversioned";
  src = ../host;
in
beamPackages.mixRelease {
  inherit pname version src;
  mixEnv = "test";
  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "${pname}-deps";
    inherit version src;
    mixEnv = "test";
    hash = "sha256-62rQBlYDMuBzdCo8lf+JG7Z9wAj5Wp18goUqbWWKp4A=";
  };
  nativeBuildInputs = lib.optional stdenv.isLinux procps;
  env = {
    KETTLECORN_RUNTIME = "${runtime}";
  };
  removeCookie = false;
  dontFixup = true;
  buildPhase = ''
    runHook preBuild
    export XDG_CACHE_HOME=$TMPDIR/cache
    mix test --max-cases 4
    for nb in notebooks/*.livemd; do mix run scripts/livebook_test.exs "$nb"; done
    runHook postBuild
  '';
  installPhase = "touch $out";
}
