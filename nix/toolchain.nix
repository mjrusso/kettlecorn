# The C toolchain for wasm32-wasip3 with cooperative threads:
#
#   resourceDir  clang's resource dir plus compiler-rt builtins built for the
#                target (cooperative threads need every object, compiler-rt
#                included, built with the thread-context libcalls)
#   sysroot      wasi-libc, ENABLE_COOP_THREADS: pthreads are component-model
#                threads, multiplexed on one OS thread
#   compat       libkettlecorn_compat.a (POSIX stubs, stdio framing, sockets
#                glue) and libkettlecorn_http.a (wasi:http client)
#   cc           `wasi-cc`, the compiler driver OTP's configure/make use
#
# clang is the unwrapped nixpkgs clang 23 (the first release with
# component-model threading); nothing here uses the host C toolchain.
{ lib
, stdenvNoCC
, writeShellScriptBin
, llvmPackages_23
, wasm-component-ld
, wit-bindgen
, wasm-tools
, wasmtimeSrc
, cmake
, ninja
, python3
, wasi-libc-src
}:
let
  llvm = llvmPackages_23;
  target = "wasm32-wasip3";
  clangMajor = lib.versions.major llvm.release_version;

  # clang, wasm-ld (lld), llvm-ar/nm/ranlib, and wasm-component-ld, which
  # clang runs as the linker for wasip2+ targets and which runs wasm-ld.
  tools = [ llvm.clang-unwrapped llvm.lld llvm.llvm wasm-component-ld ];

  resourceDir = stdenvNoCC.mkDerivation {
    pname = "clang-resource-dir-${target}";
    version = llvm.release_version;
    src = llvm.compiler-rt.src;
    nativeBuildInputs = [ cmake ninja python3 ] ++ tools;
    dontUseCmakeConfigure = true;
    dontUseNinjaBuild = true;
    dontUseNinjaInstall = true;
    buildPhase = ''
      runHook preBuild
      mkdir empty-sysroot # the builtins are freestanding
      cmake -S compiler-rt/lib/builtins -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang -DCMAKE_ASM_COMPILER=clang \
        -DCMAKE_C_COMPILER_WORKS=ON -DCMAKE_CXX_COMPILER_WORKS=ON \
        -DCMAKE_AR=$(command -v llvm-ar) -DCMAKE_RANLIB=$(command -v llvm-ranlib) \
        -DCMAKE_NM=$(command -v llvm-nm) \
        -DCMAKE_C_COMPILER_TARGET=${target} -DCMAKE_ASM_COMPILER_TARGET=${target} \
        -DCMAKE_SYSTEM_NAME=Generic -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCOMPILER_RT_BAREMETAL_BUILD=ON -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
        -DCOMPILER_RT_EXCLUDE_ATOMIC_BUILTIN=ON \
        -DCMAKE_C_FLAGS="-mthread-model posix -pthread -ftls-model=local-exec -O2" \
        -DCMAKE_SYSROOT=$PWD/empty-sysroot
      ninja -C build -j $NIX_BUILD_CORES
      runHook postBuild
    '';
    # clang finds lib/<os>/libclang_rt.builtins-<arch>.a under -resource-dir.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/wasip3
      ln -s ${llvm.clang-unwrapped.lib}/lib/clang/${clangMajor}/include $out/include
      cp $(find build -name libclang_rt.builtins-wasm32.a) $out/lib/wasip3/
      runHook postInstall
    '';
  };

  sysroot = stdenvNoCC.mkDerivation {
    pname = "wasi-libc-${target}";
    version = wasi-libc-src.shortRev or "unstable";
    src = wasi-libc-src;
    # wit-bindgen and wasm-component-ld from nixpkgs have the exact versions
    # wasi-libc asks for, and it takes any wasm-tools: it downloads nothing.
    nativeBuildInputs = [ cmake ninja python3 wit-bindgen wasm-tools ] ++ tools;
    dontUseCmakeConfigure = true;
    dontUseNinjaBuild = true;
    dontUseNinjaInstall = true;
    buildPhase = ''
      runHook preBuild
      cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_AR=$(command -v llvm-ar) \
        -DTARGET_TRIPLE=${target} \
        -DCMAKE_INSTALL_PREFIX=$out \
        -DBUILTINS_LIB=${resourceDir}/lib/wasip3/libclang_rt.builtins-wasm32.a \
        -DBUILD_SHARED=OFF -DBUILD_TESTS=OFF \
        -DENABLE_COOP_THREADS=ON
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      ninja -C build -j $NIX_BUILD_CORES install
      runHook postInstall
    '';
  };

  # Flags for everything compiled for the guest (OpenSSL, the compat shim,
  # OTP). The _WASI_EMULATED_* macros unlock wasi-libc's emulation of
  # signals, process clocks, mmap and getpid.
  #
  # -fno-strict-overflow: ERTS relies on wrapping pointer arithmetic (e.g.
  # ERL_BITS_EBS_FROM_REG adds a negative offset of type size_t to a
  # pointer). clang folds such sums into a wasm load/store's unsigned offset
  # immediate, which traps; this makes overflow well-defined instead.
  targetFlags = [
    "--target=${target}"
    "--sysroot=${sysroot}"
    "-resource-dir=${resourceDir}"
    "-pthread"
    "-D_WASI_EMULATED_SIGNAL"
    "-D_WASI_EMULATED_PROCESS_CLOCKS"
    "-D_WASI_EMULATED_MMAN"
    "-D_WASI_EMULATED_GETPID"
    "-fno-strict-overflow"
  ];
  emulatedLibs = [
    "-lwasi-emulated-signal"
    "-lwasi-emulated-process-clocks"
    "-lwasi-emulated-mman"
    "-lwasi-emulated-getpid"
  ];
  flags = lib.escapeShellArgs targetFlags;

  compat = stdenvNoCC.mkDerivation {
    pname = "kettlecorn-compat";
    version = "unversioned";
    src = lib.fileset.toSource {
      root = ../c;
      fileset = lib.fileset.unions [
        (lib.fileset.fileFilter (file: file.hasExt "c") ../c/src)
        (lib.fileset.fileFilter (file: file.hasExt "h") ../c/include)
        ../c/http/kettlecorn_http.c
        ../c/http/kettlecorn_http.h
        ../c/http/world.wit
      ];
    };
    nativeBuildInputs = [ wit-bindgen ] ++ tools;
    buildPhase = ''
      runHook preBuild
      # C bindings for wasi:http/client@0.3.0, from the WIT files of the
      # wasmtime that runs the guest.
      mkdir -p wit
      cp http/world.wit wit/
      ln -s ${wasmtimeSrc}/crates/wasi-http/src/p3/wit/deps wit/deps
      wit-bindgen c wit --out-dir http/gen

      cc() { clang ${flags} -O2 -D_GNU_SOURCE -Iinclude -include include/wasi_compat.h "$@"; }
      for f in src/*.c; do cc -Wall -c "$f" -o "$(basename "$f" .c).o"; done
      llvm-ar rcs libkettlecorn_compat.a framing.o platform.o sockets.o stubs.o wrap.o
      cc -Wno-unused-parameter -Ihttp -c http/kettlecorn_http.c -o http.o
      cc -Wno-unused-parameter -c http/gen/http_nif.c -o http_nif.o
      llvm-ar rcs libkettlecorn_http.a http.o http_nif.o
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/include
      cp libkettlecorn_compat.a libkettlecorn_http.a $out/lib/
      cp http/gen/http_nif_component_type.o $out/lib/kettlecorn_http_component_type.o
      cp -R include/. $out/include/
      cp http/kettlecorn_http.h $out/include/
      runHook postInstall
    '';
  };

  # The compiler driver for OTP's configure and make: adds the target flags,
  # force-includes the compat declarations and links the compat library.
  cc = writeShellScriptBin "wasi-cc" ''
    export PATH=${lib.makeBinPath tools}:$PATH
    # Everything is linked statically into one component; OTP's configure
    # still probes NIF/driver linking with -shared -fPIC, so drop those.
    args=()
    link=1
    conftest=0
    for a in "$@"; do
      case "$a" in
        -shared|-fPIC|-fpic) continue ;;
        -c|-E|-S|-M|-MM) link=0 ;;
        *conftest.c) conftest=1 ;;
      esac
      args+=("$a")
    done
    flags=(${flags} -D_GNU_SOURCE -I${compat}/include -Wno-unused-command-line-argument)
    # Autoconf probes declare functions with deliberately bogus prototypes,
    # which would clash with the compat declarations.
    [[ $conftest -eq 1 ]] || flags+=(-include ${compat}/include/wasi_compat.h)
    if [[ $link -eq 1 ]]; then
      # --wrap routes write()/writev() through c/src/framing.c, and
      # gethostname() to the guest's fixed name in c/src/wrap.c.
      exec ${llvm.clang-unwrapped}/bin/clang "''${flags[@]}" "''${args[@]}" \
        ${compat}/lib/libkettlecorn_compat.a ${lib.escapeShellArgs emulatedLibs} \
        -Wl,--wrap=write -Wl,--wrap=writev -Wl,--wrap=gethostname
    fi
    exec ${llvm.clang-unwrapped}/bin/clang "''${flags[@]}" "''${args[@]}"
  '';
in
{
  inherit llvm target tools targetFlags resourceDir sysroot compat cc;
}
