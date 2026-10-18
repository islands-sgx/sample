{
  lib,
  fetchurl,
  coreutils,
  gnumake,
  python3,
  writeShellScript,
  writeText,
  stdenv,
  llvmTools,
  enclaveCompiler,
  sgxSdk,
  mode,
}:
assert mode == "raw" || mode == "anchor";
let
  version = "3.03";
  revision = "e67f9e6eab43116a14751bf7166c59d98728297a";
  makeIrConsistentCompiler = name: compiler: extraArgs:
    writeShellScript name ''
      export ATFIELD_LLC=${llvmTools}/bin/llc
      export ATFIELD_NATIVE_ANCHORS=${../../scripts/inject-native-anchors.py}
      exec ${stdenv.shell} ${../../scripts/compile-ir-object.sh} \
        ${compiler} ${lib.escapeShellArgs extraArgs} "$@"
    '';
  sgxCompatHeader = writeText "mcl-sgx-compat.h" ''
    #include <stdio.h>
    extern "C" int printf(const char *, ...);
  '';
  irConsistentCxx =
    makeIrConsistentCompiler "mcl-clang++" "${stdenv.cc}/bin/c++" [
      "-m64"
      "-mno-red-zone"
      "-nostdinc"
      "-nostdinc++"
      "-include${sgxSdk}/include/libcxx/__sgx"
      "-include${sgxCompatHeader}"
      "-D_LIBCPP_HAS_NO_VENDOR_AVAILABILITY_ANNOTATIONS"
      "-I${sgxSdk}/include"
      "-I${sgxSdk}/include/tlibc"
      "-I${sgxSdk}/include/libcxx"
      "-I${sgxSdk}/include/stdc++"
      "-I${sgxSdk}/include/stdc++/linux"
    ];
in
stdenv.mkDerivation {
  pname = "mcl-sgx-${mode}";
  inherit version;

  src = fetchurl {
    name = "mcl-${revision}.tar.gz";
    url = "https://codeload.github.com/herumi/mcl/tar.gz/${revision}";
    hash = "sha256-S+6/HQwSf51/ROrFe/BOxu3Iy5QNudmcjfuURN6J/HQ=";
  };

  nativeBuildInputs = [ coreutils gnumake python3 llvmTools ];

  dontConfigure = true;
  dontStrip = true;
  NIX_CFLAGS_COMPILE = "";
  SOURCE_DATE_EPOCH = "1";
  ATFIELD_ANCHOR_PREPARATION = if mode == "anchor" then "1" else "0";
  ATFIELD_PAYLOAD_NAMESPACE = "library/mcl/${revision}";
  ATFIELD_LLC = "${llvmTools}/bin/llc";

  buildPhase = ''
    runHook preBuild

    export ATFIELD_SOURCE_ROOT="$PWD"
    export SGX_SDK=${sgxSdk}
    export CC=${enclaveCompiler}/bin/enclave-clang-ir-consistent
    export CXX=${irConsistentCxx}
    export CLANG=${enclaveCompiler}/bin/enclave-clang-ir-consistent
    export AR=${llvmTools}/bin/llvm-ar
    export RANLIB=${llvmTools}/bin/llvm-ranlib
    export NM=${llvmTools}/bin/llvm-nm

    resource_include="$(${stdenv.cc}/bin/cc -print-resource-dir)/include"
    compat_include="$PWD/compat-include"
    mkdir -p "$compat_include"
    printf '#include <string.h>\n' > "$compat_include/memory.h"
    export CFLAGS="-nostdinc -I$compat_include -I${sgxSdk}/include -I${sgxSdk}/include/tlibc -I$resource_include"

    mkdir -p obj_sgx lib_sgx bin
    make -j''${NIX_BUILD_CORES:-1} \
      DEBUG=0 \
      ARCH=x86_64 \
      MCL_USE_XBYAK=0 \
      MCL_USE_LLVM=1 \
      MCL_BINT_ASM=1 \
      MCL_BINT_ASM_X64=0 \
      MCL_MSM=0 \
      MCL_FP_BIT=256 \
      MCL_FR_BIT=256 \
      MCL_DONT_USE_OPENMP=1 \
      OBJ_DIR=obj_sgx \
      LIB_DIR=lib_sgx \
      CC="$CC" \
      CXX="$CXX" \
      CLANG="$CLANG" \
      AR="$AR" \
      CFLAGS_USER="-DMCL_DONT_USE_CSPRNG -DCYBOZU_DONT_USE_STRING -DCYBOZU_DONT_USE_EXCEPTION -DCYBOZU_HOST_UNKNOWN=0 -DCYBOZU_HOST_INTEL=1 -DCYBOZU_HOST=0 -Wa,--noexecstack" \
      lib_sgx/libmcl.a

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm0644 lib_sgx/libmcl.a "$out/lib/libmcl_sgx.a"
    install -d "$out/include"
    cp -R include/mcl "$out/include/"
    cp -R include/cybozu "$out/include/"
    install -Dm0644 COPYRIGHT "$out/share/licenses/$pname/COPYRIGHT"

    runHook postInstall
  '';

  meta = {
    homepage = "https://github.com/herumi/mcl";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
  };
}
