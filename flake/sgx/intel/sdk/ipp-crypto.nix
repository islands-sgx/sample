{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  nasm,
  openssl,
  python3,
  writeShellScript,
  llvmPackages ? null,
  llvmTools ? (if llvmPackages == null then null else llvmPackages.llvm),
  irConsistent ? false,
  anchorPreparation ? false,
  extraCmakeFlags ? [ ],
}:
assert !irConsistent || llvmPackages != null;
let
  anchorFlag = if anchorPreparation then "1" else "0";
  makeIrConsistentCompiler = name: compiler: writeShellScript name ''
    export SOURCE_DATE_EPOCH=1
    export ATFIELD_LLC=${llvmTools}/bin/llc
    export ATFIELD_NATIVE_ANCHORS=${../../../../scripts/inject-native-anchors.py}
    export ATFIELD_PYTHON=${python3}/bin/python3
    export ATFIELD_ANCHOR_PREPARATION=${anchorFlag}
    export ATFIELD_PAYLOAD_NAMESPACE=library/ipp-crypto
    exec ${stdenv.shell} ${../../../../scripts/compile-ir-object.sh} \
      ${compiler} "$@" \
      -Wno-error=sign-conversion -Wno-error=implicit-int-conversion
  '';
  irConsistentCc = makeIrConsistentCompiler "ipp-crypto-clang" "${stdenv.cc}/bin/cc";
  irConsistentCxx = makeIrConsistentCompiler "ipp-crypto-clang++" "${stdenv.cc}/bin/c++";
  nasmAnchor = writeShellScript "ipp-crypto-nasm-anchor" ''
    set -euo pipefail
    outputFile=
    args=("$@")
    for ((i = 0; i < ''${#args[@]}; i++)); do
      if [[ ''${args[i]} == -o ]] && ((i + 1 < ''${#args[@]})); then
        outputFile=''${args[i + 1]}
        break
      fi
    done
    ${nasm}/bin/nasm "$@"
    if [[ -n $outputFile ]]; then
      payloadName="library/ipp-crypto/asm/''${outputFile##*/}"
      payloadHash=$(printf '%s' "$payloadName" | sha256sum)
      payloadHash=''${payloadHash:0:16}
      printf -v payloadOrdinal '%u' "0x$payloadHash"
      ${python3}/bin/python3 ${../../../../scripts/inject-native-anchors.py} \
        "$outputFile" "$payloadOrdinal"
    fi
  '';
in
stdenv.mkDerivation rec {
  pname = "ipp-crypto";
  version = "2021.12.1";

  src = fetchFromGitHub {
    owner = "intel";
    repo = "ipp-crypto";
    rev = "ippcp_${version}";
    hash = "sha256-voxjx9Np/8jy9XS6EvUK4aW18/DGQGaPpTKm9RzuCU8=";
  };

  cmakeFlags = [
    "-DARCH=intel64"
    "-DIPPCP_FIPS_MODE=on"
  ]
  ++ lib.optionals anchorPreparation [
    "-DCMAKE_ASM_NASM_COMPILER=${nasmAnchor}"
  ]
  ++ extraCmakeFlags;

  postPatch = lib.optionalString irConsistent ''
    substituteInPlace sources/include/owndefs.h \
      --replace-fail '#endif /* __OWNDEFS_H__ */' \
      '#endif /* __OWNDEFS_H__ */

#if !defined(__INLINE)
#if defined(__INTEL_COMPILER) || defined(__INTEL_LLVM_COMPILER) || defined(_MSC_VER)
#define __INLINE static __inline
#elif defined(__GNUC__)
#define __INLINE static __inline__
#else
#define __INLINE static
#endif
#endif
#if !defined(__NOINLINE)
#if defined(__INTEL_COMPILER) || defined(_MSC_VER)
#define __NOINLINE __declspec(noinline)
#elif defined(__GNUC__) || defined(__INTEL_LLVM_COMPILER)
#define __NOINLINE __attribute__((noinline))
#else
#define __NOINLINE
#endif
#endif
#if !defined(__FORCEINLINE)
#if defined(_MSC_VER)
#define __FORCEINLINE __forceinline
#elif defined(__INTEL_COMPILER) || defined(__INTEL_LLVM_COMPILER) || defined(__GNUC__)
#define __FORCEINLINE __INLINE __attribute__((always_inline))
#else
#define __FORCEINLINE
#endif
#endif'
    substituteInPlace sources/ippcp/crypto_mb/include/crypto_mb/defs.h \
      --replace-fail '#endif /* DEFS_H */' \
      '#endif /* DEFS_H */

#if !defined(__INLINE)
#if defined(__GNUC__)
#define __INLINE static __inline__
#else
#define __INLINE static __forceinline
#endif
#endif
#if !defined(__NOINLINE)
#if defined(__GNUC__)
#define __NOINLINE __attribute__((noinline))
#else
#define __NOINLINE __declspec(noinline)
#endif
#endif'
    substituteInPlace sources/ippcp/crypto_mb/include/internal/sm3/sm3_common.h \
      --replace-fail '#include <immintrin.h>' \
      '#include <immintrin.h>
#include <crypto_mb/defs.h>'
    substituteInPlace sources/ippcp/crypto_mb/include/internal/sm4/sm4_mb.h \
      --replace-fail '#include <immintrin.h>' \
      '#include <immintrin.h>
#include <crypto_mb/defs.h>'
    substituteInPlace sources/ippcp/crypto_mb/include/internal/common/ifma_math.h \
      --replace-fail '#include <immintrin.h>' \
      '#include <immintrin.h>
#include <crypto_mb/defs.h>'
    substituteInPlace sources/ippcp/crypto_mb/include/internal/rsa/ifma_div_104_by_52.h \
      --replace-fail '#include <immintrin.h>' \
      '#include <immintrin.h>
#include <crypto_mb/defs.h>'
  '' + lib.optionalString anchorPreparation ''
    substituteInPlace sources/ippcp/asm_intel64/gcm_vaes_avx512.inc \
      --replace-fail '%endmacro                       ; INITIAL_BLOCKS_PARTIAL_CIPHER' \
      '        db 0x0f, 0x1f, 0x80, 0xc3, 0x00, 0x00, 0x00
%endmacro                       ; INITIAL_BLOCKS_PARTIAL_CIPHER' \
      --replace-fail '%endmacro                       ; INITIAL_BLOCKS_PARTIAL_GHASH' \
      '        db 0x0f, 0x1f, 0x80, 0xc3, 0x00, 0x00, 0x00
%endmacro                       ; INITIAL_BLOCKS_PARTIAL_GHASH' \

  '';

  env.NIX_CFLAGS_COMPILE =
    if irConsistent then "" else "-Wno-error=stringop-overflow";

  dontStrip = irConsistent;

  preConfigure = lib.optionalString irConsistent ''
    export ATFIELD_SOURCE_ROOT="$PWD"
    cmakeFlagsArray+=("-DCMAKE_C_COMPILER=${irConsistentCc}")
    cmakeFlagsArray+=("-DCMAKE_CXX_COMPILER=${irConsistentCxx}")
    cmakeFlagsArray+=("-DCMAKE_AR=${llvmTools}/bin/llvm-ar")
    cmakeFlagsArray+=("-DCMAKE_RANLIB=${llvmTools}/bin/llvm-ranlib")
    cmakeFlagsArray+=("-DCMAKE_C_COMPILER_AR=${llvmTools}/bin/llvm-ar")
    cmakeFlagsArray+=("-DCMAKE_C_COMPILER_RANLIB=${llvmTools}/bin/llvm-ranlib")
    cmakeFlagsArray+=("-DCMAKE_CXX_COMPILER_AR=${llvmTools}/bin/llvm-ar")
    cmakeFlagsArray+=("-DCMAKE_CXX_COMPILER_RANLIB=${llvmTools}/bin/llvm-ranlib")
  '';

  nativeBuildInputs = [
    cmake
    nasm
    openssl
    python3
  ] ++ lib.optionals irConsistent [ llvmTools ];
}
