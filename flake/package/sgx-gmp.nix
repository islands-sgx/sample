{
  lib,
  fetchFromGitHub,
  stdenv,
  coreutils,
  bun,
  gnumake,
  m4,
  runCommand,
  writeShellScript,
  llvmTools,
  enclaveCompiler,
  sgxSdk,
  implementTools,
  walletSource,
  mode,
}:
assert mode == "raw" || mode == "anchor";
let
  revision = "8b8f2ed146004ae3636789951b35790552cb0f1b";
  sgxCompatInclude = runCommand "sgx-gmp-compat" {} ''
    mkdir -p "$out"
    cat > "$out/stdio.h" <<'EOF'
    #include "${sgxSdk}/include/tlibc/stdio.h"
    int printf(const char *, ...);
    EOF
  '';
  configureCompatibleCc = writeShellScript "sgx-gmp-clang" ''
    compile=0
    source=
    hasOutput=0
    for arg in "$@"; do
      case "$arg" in
        -c) compile=1 ;;
        -o|-o?*) hasOutput=1 ;;
        *.c|*.cc|*.cpp|*.cxx|*.C|*.i|*.ii|*.ll|*.bc|*.S|*.s) source=$arg ;;
      esac
    done
    if ((compile)) && [[ -n $source ]] && ((!hasOutput)); then
      object=''${source##*/}
      object=''${object%.*}.o
      set -- "$@" -o "$object"
    fi
    case $source in
      *dump.c) set -- -I${sgxCompatInclude} "$@" ;;
    esac
    exec ${enclaveCompiler}/bin/enclave-clang-ir-consistent "$@"
  '';
in
stdenv.mkDerivation {
  outputs = if mode == "anchor" then [ "out" "bc" ] else [ "out" ];
  pname = "intel-sgx-gmp-${mode}";
  version = "6.1.2";
  src = fetchFromGitHub {
    owner = "intel";
    repo = "sgx-gmp";
    rev = revision;
    hash = "sha256-VCme5WPIwJnEI6MRnOk7Z0e6G9YjiF1P2Dik9pbY9Vk=";
    name = "sgx-gmp-${revision}";
  };

  nativeBuildInputs = [ coreutils gnumake m4 llvmTools ] ++ lib.optionals (mode == "anchor") [ bun ];
  dontConfigure = true;
  dontStrip = true;
  NIX_CFLAGS_COMPILE = "";
  SOURCE_DATE_EPOCH = "1";
  ATFIELD_ANCHOR_PREPARATION = if mode == "anchor" then "1" else "0";
  ATFIELD_PAYLOAD_NAMESPACE = "library/intel-sgx-gmp/${revision}";
  ATFIELD_LLC = "${llvmTools}/bin/llc";
  ATFIELD_EXPORT_BACKEND_BITCODE = if mode == "anchor" then "1" else null;

  buildPhase = ''
    runHook preBuild

    export ATFIELD_SOURCE_ROOT="$PWD"
    export SGX_SDK=${sgxSdk}
    export CC=${configureCompatibleCc}
    export CXX=${configureCompatibleCc}
    export AR=${llvmTools}/bin/llvm-ar
    export RANLIB=${llvmTools}/bin/llvm-ranlib
    export NM=${llvmTools}/bin/llvm-nm
    export CFLAGS="-O2 -fno-asynchronous-unwind-tables"

    ./configure \
      --build=x86_64-pc-linux-gnu \
      --host=x86_64-pc-linux-gnu \
      --prefix="$out" \
      --enable-assembly \
      --disable-shared \
      --enable-static \
      --with-pic \
      --enable-sgx \
      --with-sgxsdk="$SGX_SDK" \
      --disable-cxx
    make -j''${NIX_BUILD_CORES:-1} CFLAGS_CPU=

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm0644 libsgx_tgmp.a "$out/lib/libsgx_tgmp.a"
    install -Dm0644 gmp.h "$out/include/gmp.h"
    install -Dm0644 "${walletSource}/third_party/gmp/sgx_tgmp.h.fixed" \
      "$out/include/sgx_tgmp.h"
    for licenseFile in COPYING COPYING.LESSERv3 COPYINGv2 COPYINGv3; do
      if [[ -f "$licenseFile" ]]; then
        install -Dm0644 "$licenseFile" "$out/share/licenses/$pname/$licenseFile"
      fi
    done

    ${lib.optionalString (mode == "anchor") ''
    ${bun}/bin/bun ${implementTools}/build/codegen/collect-library-ir.ts \
      --object-root "$PWD" --package-root "$out" --output-root "$bc" \
      --llvm-ar ${llvmTools}/bin/llvm-ar --llvm-nm ${llvmTools}/bin/llvm-nm --archive "$out/lib/libsgx_tgmp.a"
    ''}
    runHook postInstall
  '';

  meta = {
    license = with lib.licenses; [ gpl3Plus lgpl3Plus ];
    platforms = [ "x86_64-linux" ];
  };
}
