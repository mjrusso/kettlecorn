# OTP for wasm32-wasip3: Popcorn's patch stack plus Kettlecorn's patches
# (patches/otp/*.patch, see patches/README.md), cross compiled with
# toolchain.nix. Produces
#
#   $out/beam.wasm        the emulator (a WASIp3 component)
#   $out/beam-http.wasm   the same, linked with the wasi:http client
#   $out/bin/vm.boot      boot script (kernel + stdlib, no .erlang)
#   $out/lib/<app>/ebin   kernel stdlib compiler crypto asn1 public_key ssl
{ lib
, stdenv
, perl
, erlang
, toolchain
, openssl
, otp-src
, popcorn-src
}:
let
  version = lib.fileContents "${otp-src}/OTP_VERSION";

  patchesIn = dir: map (name: "${dir}/${name}")
    (lib.sort lib.lessThan
      (lib.filter (lib.hasSuffix ".patch")
        (lib.attrNames (builtins.readDir dir))));

  inherit (toolchain) cc compat;
  bin = "bin/wasm32-unknown-wasi";
  replacements = {
    "erts/preloaded/src/wasm.erl" = {
      source = ../c/otp/wasm.erl;
      sha256 = "02b2cb144b7e12266418422b38604216f48433f6984f116029cb730a609e6f81";
    };
    "lib/kernel/src/inet_gethost_native.erl" = {
      source = ../c/otp/inet_gethost_native.erl;
      sha256 = "bd606be87a22f5b13a12084f09997050394acf2192f967fbdaf1fc8cefa967b4";
    };
  };

  # Linear memory starts at 64 MiB; the launcher applies its growth limit.
  linkFlags = "-Wl,--initial-memory=67108864 -Wl,-z,stack-size=1048576";
  # The wasi:http client is linked into beam-http.wasm only: the component
  # then requires the launcher to link wasi:http interfaces.
  httpLinkFlags = "-Wl,--whole-archive ${compat}/lib/libkettlecorn_http.a -Wl,--no-whole-archive"
    + " ${compat}/lib/kettlecorn_http_component_type.o";
in
assert lib.assertMsg (lib.versions.major version == lib.versions.major erlang.version)
  "OTP ${version} needs a host Erlang/OTP of the same major release, got ${erlang.version}";
stdenv.mkDerivation {
  pname = "otp-${toolchain.target}";
  inherit version;
  src = otp-src;
  patches = patchesIn "${popcorn-src}/popcorn/patches" ++ patchesIn ../patches/otp;

  # The host stdenv's compiler only builds the native bootstrap system
  # (erlc and friends for this exact OTP version); the host Erlang compiles
  # the patched preloaded modules.
  nativeBuildInputs = [ perl erlang cc ] ++ toolchain.tools;
  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  postPatch = ''
    patchShebangs --build .
    # Kettlecorn's part of the wasm NIF module; the patches hook it in.
    cp ${../c/nif}/* erts/emulator/nifs/common/
    cp ${../c/otp/kettlecorn.mk} erts/emulator/kettlecorn.mk
    cp ${../c/include/kettlecorn_platform.h} erts/include/internal/kettlecorn_platform.h
    ${lib.concatStrings (lib.mapAttrsToList (target: replacement: ''
      echo '${replacement.sha256}  ${target}' | sha256sum --check
      cp ${replacement.source} ${target}
    '') replacements)}
    # OTP checks in the preloaded BEAM files; source changes need recompiling.
    for m in wasm erl_init prim_inet; do
      erlc +deterministic -I lib/kernel/src -I lib/kernel/include \
        -o erts/preloaded/ebin erts/preloaded/src/$m.erl
    done
  '';

  configurePhase = ''
    runHook preConfigure
    export ERL_TOP=$PWD

    echo "== native bootstrap system"
    ./configure --enable-bootstrap-only --without-termcap
    make -j $NIX_BUILD_CORES

    echo "== configuring for wasm32-unknown-wasi"
    # Answers configure can't find out when cross compiling, and functions
    # WASI doesn't have (or that the compat shim only stubs).
    export ac_cv_func_pthread_create=yes ac_cv_header_pthread_h=yes
    export ac_cv_sizeof_short=2 ac_cv_sizeof_int=4 ac_cv_sizeof_long=4
    export ac_cv_sizeof_long_long=8 ac_cv_sizeof_void_p=4 ac_cv_c_bigendian=no
    export erl_xcomp_bigendian=no erl_xcomp_clock_gettime_cpu_time=no
    export erl_xcomp_getaddrinfo=yes erl_xcomp_kqueue=no erl_xcomp_poll=yes
    export erl_xcomp_reliable_fpe=no erl_xcomp_posix_memalign=yes
    export erl_xcomp_putenv_copy=yes
    export ac_cv_func_mremap=no ac_cv_func_sbrk=no ac_cv_func_brk=no
    export ac_cv_func_vsyslog=no ac_cv_func_ppoll=no ac_cv_func_mallopt=no
    export ac_cv_func_getrlimit=no ac_cv_func_setrlimit=no ac_cv_func_setsid=no
    export ac_cv_func_sigaltstack=no
    # Sockets come from wasi:sockets, which has no Unix domain sockets.
    export ac_cv_header_sys_un_h=no
    export erl_xcomp_sysroot=${openssl} erl_xcomp_isysroot=${openssl}
    export LIBS="-L${openssl}/lib -lcrypto"

    CC=wasi-cc LD=wasi-cc AR=llvm-ar RANLIB=llvm-ranlib CFLAGS=-O2 LDFLAGS= \
    ./configure \
      --host=wasm32-unknown-wasi --build=$(make/autoconf/config.guess) \
      --prefix=/otp \
      --disable-jit --disable-sctp --disable-kernel-poll \
      --disable-security-hardening-flags --disable-largefile \
      --without-termcap --without-dynamic-trace --disable-vm-probes \
      --without-threadnames --enable-builtin-zlib --disable-esock \
      --with-ssl=${openssl} --disable-dynamic-ssl-lib --enable-static-nifs=yes \
      --without-ssh --without-wx --without-javac --without-odbc --without-jinterface \
      --without-common_test --without-diameter --without-edoc --without-eldap \
      --without-eunit --without-ftp --without-reltool --without-snmp \
      --without-tftp --without-tools --without-debugger --without-dialyzer \
      --without-et --without-megaco --without-observer --without-os_mon \
      --without-parsetools --without-mnesia --without-xmerl \
      --without-runtime_tools
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    export PATH=$ERL_TOP/bootstrap/bin:$PATH
    # The WASI runtime never starts OTP's Unix child-setup helper.
    mk() { make TARGET=wasm32-unknown-wasi UNIX_ONLY_BUILDS= DEXPORT= -j $NIX_BUILD_CORES "$@"; }

    echo "== emulator"
    # -k: OTP's helper programs (erlexec, heart, ...) don't build for WASI and
    # aren't needed; the emulator is linked explicitly below.
    EXTRA_EMCC_LINK_FLAGS="${linkFlags}" mk -k emulator || true
    # The static crypto/asn1 NIFs must exist before the emulator links.
    mk -C lib/crypto
    mk -C lib/asn1

    # Link twice; make only links when beam.emu/beam.smp are missing.
    rm -f ${bin}/beam.emu ${bin}/beam.smp
    EXTRA_EMCC_LINK_FLAGS="${linkFlags} ${httpLinkFlags}" mk -C erts/emulator opt
    mv ${bin}/beam.smp beam-http.wasm
    rm -f ${bin}/beam.emu
    EXTRA_EMCC_LINK_FLAGS="${linkFlags}" mk -C erts/emulator opt
    mv ${bin}/beam.smp beam.wasm

    echo "== applications"
    # erl_interface is a C library for C nodes; not needed in the guest.
    echo "Not built for WASI" > lib/erl_interface/SKIP
    mk libs
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib
    cp beam.wasm beam-http.wasm $out/
    cp bootstrap/bin/no_dot_erlang.boot $out/bin/vm.boot
    for app in kernel stdlib compiler crypto asn1 public_key ssl; do
      mkdir -p $out/lib/$app
      cp -R lib/$app/ebin $out/lib/$app/
      [[ -d lib/$app/priv ]] && cp -R lib/$app/priv $out/lib/$app/ || true
    done
    runHook postInstall
  '';

  dontFixup = true;
}
