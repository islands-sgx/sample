{
  lib,
  fetchurl,
  coreutils,
  stdenv,
  llvmTools,
  bun,
  implementTools,
  enclaveCompiler,
  sgxSdk,
  mode,
}:
assert mode == "raw" || mode == "anchor";
let
  version = "5.9.2-stable";
  revision = "ac01707f552c611fbd135cc723b2682b3e7f80f2";
  sources = [
    "wolfcrypt/src/pwdbased.c"
    "wolfcrypt/src/hmac.c"
    "wolfcrypt/src/sha256.c"
    "wolfcrypt/src/hash.c"
    "wolfcrypt/src/cpuid.c"
  ];
  nativeOnlySources = [ "wolfcrypt/src/sha256_asm.S" ];
in
stdenv.mkDerivation {
  outputs = if mode == "anchor" then [ "out" "bc" ] else [ "out" ];
  pname = "wolfssl-sgx-${mode}";
  inherit version;

  src = fetchurl {
    url = "https://github.com/wolfSSL/wolfssl/archive/${revision}.tar.gz";
    hash = "sha256-8eEh4stWqkD4XrCZURbJhY0tjxhMCEKOai22a5fiyQM=";
  };

  nativeBuildInputs = [ coreutils stdenv.cc llvmTools ] ++ lib.optionals (mode == "anchor") [ bun ];
  strictDeps = true;
  dontConfigure = true;
  dontStrip = true;
  NIX_CFLAGS_COMPILE = "";
  SOURCE_DATE_EPOCH = "1";
  ATFIELD_ANCHOR_PREPARATION = if mode == "anchor" then "1" else "0";
  ATFIELD_PAYLOAD_NAMESPACE = "library/wolfssl/${revision}";
  ATFIELD_LLC = "${llvmTools}/bin/llc";
  ATFIELD_EXPORT_BACKEND_BITCODE = if mode == "anchor" then "1" else null;

  postPatch = ''
    install -m 0644 ${./wolfssl-user_settings.h}       wolfssl/wolfcrypt/user_settings.h
    sh scripts/user_settings_asm.sh "-I$PWD/wolfssl/wolfcrypt"
  '';

  buildPhase = ''
    runHook preBuild
    export ATFIELD_SOURCE_ROOT="$PWD"
    mkdir -p build

    flags=(
      -m64 -mno-red-zone -std=c99 -O2 -nostdinc -ffreestanding -fvisibility=hidden -fpie
      -fno-strict-aliasing -fwrapv -fno-delete-null-pointer-checks
      -fzero-call-used-regs=used-gpr -fstack-protector-strong
      -ftrivial-auto-var-init=pattern -Werror=format-security
      -fno-builtin-printf
      -ffunction-sections -fdata-sections
      -DWOLFSSL_USER_SETTINGS
      -I. -I./wolfssl/wolfcrypt -I${sgxSdk}/include -I${sgxSdk}/include/tlibc
      -I${stdenv.cc}/resource-root/include
      -ffile-prefix-map="$PWD"=. -fdebug-prefix-map="$PWD"=.
    )

    objects=()
    for source in ${lib.escapeShellArgs sources}; do
      unit=$(basename "$source" .c)
      native="build/$unit.o"
      "${enclaveCompiler}/bin/enclave-clang-ir-consistent"         -D_LIBCPP_SGX_CONFIG "''${flags[@]}" -c "$source" -o "$native"
      objects+=("$native")
    done

    for source in ${lib.escapeShellArgs nativeOnlySources}; do
      unit=$(basename "$source")
      unit=''${unit%.*}
      native="build/$unit.o"
      "${enclaveCompiler}/bin/enclave-clang-ir-consistent"         -D_LIBCPP_SGX_CONFIG "''${flags[@]}" -fintegrated-as -c "$source" -o "$native"
      objects+=("$native")
    done

    "${llvmTools}/bin/llvm-ar" crD build/libwolfssl-sgx.a "''${objects[@]}"
    "${llvmTools}/bin/llvm-ranlib" -D build/libwolfssl-sgx.a
    "${llvmTools}/bin/llvm-nm" --undefined-only build/libwolfssl-sgx.a       | awk '$NF ~ /^(malloc|calloc|realloc|free|wolfCrypt_Init)$/ {
          print "forbidden undefined symbol: " $NF > "/dev/stderr"; found = 1
        } END { exit found }'
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/include" "$out/lib"
    cp -R wolfssl "$out/include/"
    install -Dm0644 build/libwolfssl-sgx.a "$out/lib/libwolfssl-sgx.a"
    for licenseFile in LICENSE LICENSE.txt COPYING COPYING.txt; do
      if [[ -f "$licenseFile" ]]; then
        install -Dm0644 "$licenseFile" "$out/share/licenses/$pname/$licenseFile"
      fi
    done
    ${lib.optionalString (mode == "anchor") ''
    ${bun}/bin/bun ${implementTools}/build/codegen/collect-library-ir.ts \
      --object-root "$PWD" --package-root "$out" --output-root "$bc" \
      --llvm-ar ${llvmTools}/bin/llvm-ar --llvm-nm ${llvmTools}/bin/llvm-nm --archive "$out/lib/libwolfssl-sgx.a"
    ''}
    runHook postInstall
  '';

  meta = {
    homepage = "https://www.wolfssl.com/";
    license = lib.licenses.gpl2Plus;
    platforms = [ "x86_64-linux" ];
  };
}
