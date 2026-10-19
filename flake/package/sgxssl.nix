{
  lib,
  fetchurl,
  patch,
  perl,
  bun,
  which,
  writeShellScript,
  writeTextDir,
  stdenv,
  llvmTools,
  enclaveCompiler,
  implementTools,
  sgxSdk,
  mode,
}:
assert mode == "raw" || mode == "anchor";
let
  version = "3.0_Rev5.4";
  revision = "c3a527695679a5912081ac0cf461334cb962e1fa";
  opensslVersion = "3.0.21";

  makeIrConsistentCompiler = name: compiler: extraArgs:
    writeShellScript name ''
      export ATFIELD_LLC=${llvmTools}/bin/llc
      export ATFIELD_NATIVE_ANCHORS=${implementTools}/build/anchor/inject-native-anchors.ts
      exec ${implementTools}/bin/atfield-compile-object \
        ${compiler} ${lib.escapeShellArgs extraArgs} "$@"
    '';
  irConsistentCc =
    makeIrConsistentCompiler "sgxssl-clang" "${stdenv.cc}/bin/cc"
      fixedCpuArgs;
  irConsistentCxx =
    makeIrConsistentCompiler "sgxssl-clang++" "${stdenv.cc}/bin/c++"
      (fixedCpuArgs ++ [
        "-include"
        "${sgxSdk}/include/libcxx/__sgx"
        "-D_LIBCPP_HAS_NO_VENDOR_AVAILABILITY_ANNOTATIONS"
      ]);
  opensslSrc = fetchurl {
    url = "https://github.com/openssl/openssl/releases/download/openssl-${opensslVersion}/openssl-${opensslVersion}.tar.gz";
    hash = "sha256-YX4pr45CH0ZklISkk35IxoXkf0ZIgWfJgviLxOwdUi8=";
  };
  cpuProfileInclude = writeTextDir "include/sgxssl_cpu_profile.h"
    (builtins.readFile ../../common/sgxssl_cpu_profile.h);
  fixedCpuArgs = [
    "-DSGXSSL_FIXED_CPU_PROFILE"
    "-I${cpuProfileInclude}/include"
  ];
in
stdenv.mkDerivation {
  pname = "intel-sgx-ssl-${mode}";
  inherit version;

  src = fetchurl {
    url = "https://github.com/intel/intel-sgx-ssl/archive/${revision}.tar.gz";
    hash = "sha256-l2Yq0d01M1c06oBOE2wa3wUzcIwOBSAZwdH5mKU40S4=";
  };

  patches = [ ./patches/sgxssl-fixed-cpu.patch ];

  nativeBuildInputs = [
    patch
    llvmTools
    perl
    bun
    which
  ];

  dontConfigure = true;
  dontStrip = true;
  doCheck = true;
  enableParallelBuilding = true;
  NIX_CFLAGS_COMPILE = "";
  SOURCE_DATE_EPOCH = "1";
  ATFIELD_ANCHOR_PREPARATION = if mode == "anchor" then "1" else "0";
  ATFIELD_PAYLOAD_NAMESPACE = "library/intel-sgx-ssl/${revision}";
  ATFIELD_LLC = "${llvmTools}/bin/llc";

  postPatch = ''
    patchShebangs Linux/build_openssl.sh
    substituteInPlace Linux/build_openssl.sh \
      --replace-fail 'CC_VERSION=`gcc -dumpversion`' \
                     'CC_VERSION=`"$CC" -dumpversion`'
    substituteInPlace Linux/build_openssl.sh \
      --replace-fail 'tar xvf $OPENSSL_VERSION.tar.gz > /dev/null || exit 1' \
                     'tar xvf $OPENSSL_VERSION.tar.gz > /dev/null || exit 1
patch -d "$OPENSSL_VERSION" -p1 --batch < ${./patches/openssl-fixed-cpu.patch} || exit 1'
  '' + lib.optionalString (mode == "anchor") ''
    substituteInPlace Linux/build_openssl.sh \
      --replace-fail "sed -i '/BSAES_ASM/d' \$OPENSSL_VERSION/Configure" \
                     "sed -i '/BSAES_ASM/d' \$OPENSSL_VERSION/Configure
patch -d \"\$OPENSSL_VERSION\" -p1 --batch --forward --fuzz=0 < ${./patches/openssl-3.0.21-anchor.patch} || exit 1"
  '';

  buildPhase = ''
    runHook preBuild

    export ATFIELD_SOURCE_ROOT="$PWD"
    cp ${opensslSrc} openssl_source/openssl-${opensslVersion}.tar.gz
    chmod +w openssl_source/openssl-${opensslVersion}.tar.gz

    export SGX_SDK=${sgxSdk}
    export SGX_MODE=HW
    export SGX_ARCH=x64
    export DEBUG=0
    export NO_THREADS=1
    export OSSL3ONLY=0
    export FIPS=0
    export VERBOSE=1
    export CC=${irConsistentCc}
    export CXX=${irConsistentCxx}
    export AR=${llvmTools}/bin/llvm-ar
    export RANLIB=${llvmTools}/bin/llvm-ranlib
    export NM=${llvmTools}/bin/llvm-nm

    make -C Linux -j$NIX_BUILD_CORES sgxssl_no_mitigation

    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck

    test_dir="$TMPDIR/sgxssl-fixed-cpu-check"
    mkdir -p "$test_dir"
    ${stdenv.cc}/bin/cc -std=c99 -Wall -Wextra -Werror -UNDEBUG \
      -I${cpuProfileInclude}/include \
      ${../../tests/sgxssl_cpu_profile_test.c} \
      -o "$test_dir/profile-predicate"
    "$test_dir/profile-predicate"

    openssl_dir="openssl_source/openssl-${opensslVersion}"
    ${stdenv.cc}/bin/cc -std=gnu99 -O2 -Wall -Wextra -UNDEBUG \
      -DSGXSSL_FIXED_CPU_PROFILE -DOPENSSL_CPUID_OBJ -DTEST_XFRM=0xe7 \
      -I${cpuProfileInclude}/include -I${sgxSdk}/include \
      -I"$openssl_dir" -I"$openssl_dir/include" -I"$openssl_dir/crypto/include" \
      ${../../tests/sgxssl_fixed_cpu_init_test.c} \
      Linux/sgx/libsgx_tsgxssl/texceptions.c \
      "$openssl_dir/crypto/cpuid.c" \
      -o "$test_dir/fixed-init-positive"
    "$test_dir/fixed-init-positive"
    OPENSSL_ia32cap=0:0 "$test_dir/fixed-init-positive"

    ${stdenv.cc}/bin/cc -std=gnu99 -O2 -Wall -Wextra -UNDEBUG \
      -DSGXSSL_FIXED_CPU_PROFILE -DOPENSSL_CPUID_OBJ -DTEST_XFRM=0x7 \
      -I${cpuProfileInclude}/include -I${sgxSdk}/include \
      -I"$openssl_dir" -I"$openssl_dir/include" -I"$openssl_dir/crypto/include" \
      ${../../tests/sgxssl_fixed_cpu_init_test.c} \
      Linux/sgx/libsgx_tsgxssl/texceptions.c \
      "$openssl_dir/crypto/cpuid.c" \
      -o "$test_dir/fixed-init-negative"

    set +e
    (ulimit -c 0; "$test_dir/fixed-init-negative")
    status=$?
    set -e
    if [ "$status" -ne 134 ]; then
      echo "fixed-init-negative exited $status, expected 134" >&2
      exit 1
    fi
    echo "fixed-init-negative status=$status"

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    install -d "$out/include" "$out/lib"
    cp -R Linux/package/include/. "$out/include/"
    install -m 0644 "${cpuProfileInclude}/include/sgxssl_cpu_profile.h" \
      "$out/include/sgxssl_cpu_profile.h"
    for archive in \
      libsgx_tsgxssl_crypto.a \
      libsgx_tsgxssl.a \
      libsgx_usgxssl.a; do
      install -m 0644 "Linux/package/lib64/$archive" "$out/lib/$archive"
    done

    runHook postInstall
  '';

  meta = {
    homepage = "https://github.com/intel/intel-sgx-ssl";
    license = lib.licenses.bsd3;
    platforms = [ "x86_64-linux" ];
  };
}
