{
  stdenv,
  binutils,
  callPackage,
  file,
  git,
  autoconf,
  automake,
  libtool,
  llvmPackages,
  python3,
  which,
  writeShellScript,
  sdk,
  llvmTools ? llvmPackages.llvm,
  mode ? "raw",
}:
assert mode == "raw" || mode == "anchor";
let
  anchorFlag = if mode == "anchor" then "1" else "0";
  makeIrConsistentCompiler = name: compiler: writeShellScript name ''
    export SOURCE_DATE_EPOCH=1
    export ATFIELD_LLC=${llvmTools}/bin/llc
    export ATFIELD_NATIVE_ANCHORS=${../../../../scripts/inject-native-anchors.py}
    export ATFIELD_PYTHON=${python3}/bin/python3
    export ATFIELD_ANCHOR_PREPARATION=${anchorFlag}
    export ATFIELD_PAYLOAD_NAMESPACE=library/sgx-trusted-libs
    exec ${stdenv.shell} ${../../../../scripts/compile-ir-object.sh} \
      ${compiler} "$@" \
      -Wno-error=sign-conversion \
      -Wno-error=implicit-int-conversion \
      -Wno-error=cast-align \
      -Wno-error=vla-cxx-extension \
      -Wno-error=strict-prototypes \
      -Wno-unknown-warning-option
  '';
  irConsistentCc = makeIrConsistentCompiler "sgx-trusted-clang" "${stdenv.cc}/bin/cc";
  irConsistentCxx = makeIrConsistentCompiler "sgx-trusted-clang++" "${stdenv.cc}/bin/c++";
  ippCrypto = callPackage ./ipp-crypto.nix {
    inherit stdenv llvmPackages llvmTools;
    irConsistent = true;
    anchorPreparation = mode == "anchor";
    extraCmakeFlags = [
      "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY"
    ];
  };
in
stdenv.mkDerivation {
  pname = "sgx-trusted-libs-${mode}";
  inherit (sdk) version src;

  dontUseCmakeConfigure = true;
  dontStrip = true;
  enableParallelBuilding = true;
  hardeningDisable = [ "all" ];
  NIX_CFLAGS_COMPILE = "";

  nativeBuildInputs = [
    autoconf
    automake
    file
    git
    libtool
    llvmTools
    python3
    which
  ];

  BINUTILS_DIR = "${binutils}/bin";

  postPatch = ''
    patchShebangs external/sgx-emm/create_symlink.sh
    ./external/sgx-emm/create_symlink.sh
    (cd external/libcxxrt/libcxxrt_code && git apply ../sgx_libcxxrt.patch)
  '';

  preBuild = ''
    export ATFIELD_SOURCE_ROOT="$PWD"
    export CC=${irConsistentCc}
    export CXX=${irConsistentCxx}

    install -D -m 0644 ${ippCrypto}/lib/intel64/libippcp.a \
      external/ippcp_internal/lib/linux/intel64/no_mitigation/libippcp.a
    cp -r ${ippCrypto}/include/. external/ippcp_internal/inc/
    mkdir -p external/ippcp_internal/inc/ippcp
    install -m 0644 ${ippCrypto}/include/fips_cert.h \
      external/ippcp_internal/inc/ippcp/fips_cert.h
    install -m 0644 ${ippCrypto}/include/ippcp.h \
      external/ippcp_internal/inc/ippcp.h
    patch external/ippcp_internal/inc/ippcp.h \
      -i external/ippcp_internal/inc/ippcp21u12.patch
  '';

  buildPhase = ''
    runHook preBuild

    make -j''${NIX_BUILD_CORES:-1} -C sdk ARCH=x86_64 \
      tstdc trts tservice tcxx
    make -j''${NIX_BUILD_CORES:-1} -C sdk/tlibcrypto ARCH=x86_64 all

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm0644 build/linux/libsgx_trts.a "$out/lib/libsgx_trts.a"
    install -Dm0644 build/linux/libsgx_tstdc.a "$out/lib/libsgx_tstdc.a"
    install -Dm0644 build/linux/libsgx_tcrypto.a "$out/lib/libsgx_tcrypto.a"
    install -Dm0644 build/linux/libsgx_tservice.a "$out/lib/libsgx_tservice.a"
    install -Dm0644 build/linux/libsgx_tcxx.a "$out/lib/libsgx_tcxx.a"

    runHook postInstall
  '';
}
