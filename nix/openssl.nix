# A static OpenSSL (libcrypto + libssl) for the guest, linked into the
# emulator with OTP's crypto NIF. Randomness comes from getentropy(), which
# wasi-libc implements with wasi:random.
{ lib, stdenvNoCC, perl, openssl_3_5, toolchain }:
stdenvNoCC.mkDerivation {
  pname = "openssl-${toolchain.target}";
  inherit (openssl_3_5) version src;
  nativeBuildInputs = [ perl ] ++ toolchain.tools;
  postPatch = "patchShebangs .";
  # linux-generic32: plain C, 32-bit pointers. No sockets (OTP's ssl app uses
  # Erlang sockets; the crypto NIF needs none), no dynamic loading, no secure
  # heap (mmap/mlock), no threads of its own, no console UI.
  configurePhase = ''
    runHook preConfigure
    CC=clang AR=llvm-ar RANLIB=llvm-ranlib \
    CFLAGS="${lib.escapeShellArgs toolchain.targetFlags} -O2" \
    perl ./Configure linux-generic32 \
      no-shared no-dso no-module no-asm no-afalgeng no-devcryptoeng no-tests \
      no-sock no-dgram no-srtp no-ui-console no-secure-memory no-engine \
      no-async no-apps no-docs no-thread-pool no-default-thread-pool \
      no-comp no-cast no-idea no-seed no-camellia no-whirlpool no-siphash \
      no-ec2m no-sm2 no-sm3 no-sm4 no-blake2 no-bf no-rc2 no-rc4 no-rmd160 \
      no-md4 no-srp no-dsa no-legacy \
      --prefix=$out --openssldir=$out/ssl --libdir=lib
    runHook postConfigure
  '';
  buildPhase = ''
    runHook preBuild
    make -j $NIX_BUILD_CORES build_libs
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    make install_dev
    runHook postInstall
  '';
}
