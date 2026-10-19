{
  lib,
  stdenv,
  fetchFromGitHub,
  autoconf,
  automake,
  binutils,
  callPackage,
  cmake,
  coreutils,
  file,
  gdb,
  git,
  libtool,
  ocaml,
  ocamlPackages,
  openssl,
  ncurses,
  which,
  perl,
  python3,
  texinfo,
  validatePkgConfig,
  versionCheckHook,
  writeShellScript,
  writeText,
  debug ? false,
}:
stdenv.mkDerivation (rec {
  pname = "sgx-sdk";
  # Version as given in se_version.h.
  version = "2.29.100.1";
  src = fetchFromGitHub {
    owner = "islands-sgx";
    repo = "intel-confidentialComputing_sgx";
    rev = "e36f39f7fdf101560e46141ac0a68baead2fc7cb";
    hash = "sha256-/otbCTIV+q3vHj/fSoR5ipsXrYpHcNbIIPaejqv6Mr8=";
    fetchSubmodules = true;
  };


  postPatch = ''
    patchShebangs linux/installer/bin/build-installpkg.sh \
      linux/installer/common/sdk/createTarball.sh \
      linux/installer/common/sdk/install.sh \
      external/sgx-emm/create_symlink.sh

    export CC=${stdenv.cc}/bin/cc
    export CXX=${stdenv.cc}/bin/c++
    export CMAKE_C_COMPILER=$CC
    export CMAKE_CXX_COMPILER=$CXX

    make -j''${NIX_BUILD_CORES:-1} ATFIELD_OFFLINE_PREPARATION=1 preparation

    # Update edger8r sources for OCaml 5 compatibility.
    sed -i 's/let failwithf fmt = kprintf failwith fmt;;/let failwithf fmt = ksprintf failwith fmt;;/' \
      sdk/edger8r/linux/Util.ml
    sed -i '/| Ast\\.PTPtr(atype, _) -> is_foreign_atype atype/{n;/| _                   -> (false, \"\")/d;}' \
      sdk/edger8r/linux/CodeGen.ml

    # Ensure ocamlbuild uses Nix-provided ocaml toolchain, not host /usr.
    ocamlcPath="${ocaml}/bin/ocamlc"
    ocamloptPath="${ocaml}/bin/ocamlopt"
    ocamllibPath="${ocaml}/lib/ocaml"
    sed -i -E "s#(^[[:space:]]*)ocamlbuild[[:space:]]+#\\1OCAMLC=$ocamlcPath OCAMLOPT=$ocamloptPath OCAMLLIB=$ocamllibPath ocamlbuild #g" \
      sdk/edger8r/linux/Makefile
    sed -i -E "s#(ocamlbuild)([[:space:]]+)#\\1 -ocamlc $ocamlcPath -ocamlopt $ocamloptPath \\2#g" sdk/edger8r/linux/Makefile

    # Use Nix OpenSSL instead of Intel's prebuilt copy.
    substituteInPlace sdk/sign_tool/SignTool/Makefile \
      --replace-fail 'PREBUILT_OPENSSL_DIR := $(LINUX_EXTERNAL_DIR)/dcap_source/prebuilt/openssl' 'PREBUILT_OPENSSL_DIR := ${openssl.out}' \
      --replace-fail '$(PREBUILT_OPENSSL_DIR)/lib/linux64' '${openssl.out}/lib' \
      --replace-fail '$(PREBUILT_OPENSSL_DIR)/inc' '${openssl.dev}/include'

    # ttls also builds sdk/ttls/cert_verifier.o, with enclave-only flags.
    # Keep the host object local so parallel ttls/utls builds cannot overwrite it.
    substituteInPlace sdk/utls/Makefile \
      --replace-fail 'PREBUILD_OPENSSL_PATH ?= $(SGX_QV_PATH)/../prebuilt/openssl' \
                     'PREBUILD_OPENSSL_PATH := ${openssl.out}' \
      --replace-fail '$(PREBUILD_OPENSSL_PATH)/inc' '${openssl.dev}/include' \
      --replace-fail 'CERT_OBJ := $(HOST_CERT_SRC:.cpp=.o)' 'CERT_OBJ := cert_verifier.o'

    substituteInPlace sdk/ttls/Makefile \
      --replace-fail 'PREBUILT_OPENSSL_PATH ?= $(SGX_QV_PATH)/../prebuilt/openssl' \
                     'PREBUILT_OPENSSL_PATH := ${openssl.dev}' \
      --replace-fail '$(PREBUILT_OPENSSL_PATH)/inc' '$(PREBUILT_OPENSSL_PATH)/include'

    substituteInPlace sdk/simulation/uae_service_sim/linux/Makefile \
      --replace-fail 'PREBUILT_OPENSSL_DIR := $(LINUX_EXTERNAL_DIR)/dcap_source/prebuilt/openssl' \
                     'PREBUILT_OPENSSL_DIR := ${openssl.out}' \
      --replace-fail 'CRYPTO_LIB := -L$(PREBUILT_OPENSSL_DIR)/lib/linux64 -lcrypto' \
                     'CRYPTO_LIB := -L${openssl.out}/lib -lcrypto' \
      --replace-fail '$(PREBUILT_OPENSSL_DIR)/inc' '${openssl.dev}/include'

    substituteInPlace sdk/simulation/urtssim/linux/Makefile \
      --replace-fail 'PREBUILT_OPENSSL_DIR := $(LINUX_EXTERNAL_DIR)/dcap_source/prebuilt/openssl' \
                     'PREBUILT_OPENSSL_DIR := ${openssl.out}' \
      --replace-fail 'CRYPTO_LIB := -L$(PREBUILT_OPENSSL_DIR)/lib/linux64 -lcrypto' \
                     'CRYPTO_LIB := -L${openssl.out}/lib -lcrypto' \
      --replace-fail '$(PREBUILT_OPENSSL_DIR)/inc' '${openssl.dev}/include'

    substituteInPlace external/cbor/Makefile \
      --replace-fail 'cd $(SGX_CBOR_SRC)/build && cmake ../ $(SGX_CBOR_CONFIG) -DCMAKE_C_ENCLAVE_FLAGS="$(C_ENCLAVE_FLAGS)" && $(MAKE) && make install && cd ../..' \
                     'cd $(SGX_CBOR_SRC)/build && rm -rf CMakeFiles && rm -f CMakeCache.txt && CC=${stdenv.cc}/bin/cc CXX=${stdenv.cc}/bin/c++ cmake ../ $(SGX_CBOR_CONFIG) -DCMAKE_C_COMPILER=${stdenv.cc}/bin/cc -DCMAKE_CXX_COMPILER=${stdenv.cc}/bin/c++ -DCMAKE_C_ENCLAVE_FLAGS="$(C_ENCLAVE_FLAGS)" -DCMAKE_INSTALL_LIBDIR=lib && $(MAKE) && make install && cd ../..'


  '';

  # We need `cmake` as a build input but don't use it to kick off the build phase.
  dontUseCmakeConfigure = true;
  enableParallelBuilding = true;

  # SDK built with stackprotector produces broken enclaves which crash at runtime.
  # Disable all to be safe, SDK build configures compiler mitigations manually.
  hardeningDisable = [ "all" ];

  nativeBuildInputs = [
    autoconf
    automake
    cmake
    file
    git
    ocaml
    ocamlPackages.ocamlbuild
    ncurses
    which
    perl
    python3
    texinfo
    validatePkgConfig
  ];

  buildInputs = [
    libtool
    openssl
  ];

  sgxAsmPpScript = stdenv.mkDerivation {
    pname = "sgx-asm-pp";
    inherit version;
    src = src;
    nativeBuildInputs = [ python3 ];
    dontUnpack = true;
    installPhase = ''
      set -eu
      mkdir build-scripts
      cp $src/build-scripts/sgx-asm-pp.py build-scripts/sgx-asm-pp.py
      chmod +w build-scripts/sgx-asm-pp.py

      python3 -W error::SyntaxWarning -m py_compile build-scripts/sgx-asm-pp.py

      install -Dm0644 build-scripts/sgx-asm-pp.py $out/sgx-asm-pp.py
    '';
  };

  BINUTILS_DIR = "${binutils}/bin";

  # Build external/ippcp_internal first. The Makefile is rewritten to make the
  # build faster by splitting different versions of ipp-crypto builds and to
  # avoid patching the Makefile for reproducibility issues.
  preBuild =
    let
      ipp-crypto-no_mitigation = callPackage ./ipp-crypto.nix { };

      sgx-asm-pp = "python ${sgxAsmPpScript}/sgx-asm-pp.py --assembler=nasm";

      nasm-load = writeShellScript "nasm-load" "${sgx-asm-pp} --MITIGATION-CVE-2020-0551=LOAD $@";
      ipp-crypto-cve_2020_0551_load = callPackage ./ipp-crypto.nix {
        extraCmakeFlags = [ "-DCMAKE_ASM_NASM_COMPILER=${nasm-load}" ];
      };

      nasm-cf = writeShellScript "nasm-cf" "${sgx-asm-pp} --MITIGATION-CVE-2020-0551=CF $@";
      ipp-crypto-cve_2020_0551_cf = callPackage ./ipp-crypto.nix {
        extraCmakeFlags = [ "-DCMAKE_ASM_NASM_COMPILER=${nasm-cf}" ];
      };
    in
    ''
      echo "Setting up IPP crypto build artifacts"

      pushd 'external/ippcp_internal'

      install -D -m a+rw ${ipp-crypto-no_mitigation}/lib/intel64/libippcp.a \
        lib/linux/intel64/no_mitigation/libippcp.a
      install -D -m a+rw ${ipp-crypto-cve_2020_0551_load}/lib/intel64/libippcp.a \
        lib/linux/intel64/cve_2020_0551_load/libippcp.a
      install -D -m a+rw ${ipp-crypto-cve_2020_0551_cf}/lib/intel64/libippcp.a \
        lib/linux/intel64/cve_2020_0551_cf/libippcp.a

      cp -r ${ipp-crypto-no_mitigation}/include/* inc/

      mkdir inc/ippcp
      cp ${ipp-crypto-no_mitigation}/include/fips_cert.h inc/ippcp/

      install -m 0644 ${ipp-crypto-no_mitigation}/include/ippcp.h inc/ippcp.h
      patch inc/ippcp.h -i ./inc/ippcp21u12.patch

      install -D ${ipp-crypto-no_mitigation.src}/LICENSE license/LICENSE

      popd
    '';

  buildFlags = [
    "sdk_install_pkg"
  ]
  ++ lib.optionals debug [
    "DEBUG=1"
  ];

  postBuild = ''
    patchShebangs linux/installer/bin/sgx_linux_x64_sdk_${version}.bin
  '';

  installPhase = ''
    runHook preInstall

    installDir=$TMPDIR
    ./linux/installer/bin/sgx_linux_x64_sdk_${version}.bin -prefix $installDir
    installDir=$installDir/sgxsdk

    echo "Move files created by installer"

    mkdir -p $out/bin
    pushd $out

    mv $installDir/bin/sgx-gdb $out/bin
    mkdir $out/bin/x64
    for file in $installDir/bin/x64/*; do
      mv $file bin/
      ln -sr bin/$(basename $file) bin/x64/
    done
    rmdir $installDir/bin/{x64,}

    # Move `lib64` to `lib` and symlink `lib64`.
    mv $installDir/lib64 lib
    ln -s lib/ lib64

    # Fixup the symlinks for libsgx_urts.so.* -> libsgx_urts.so.
    for file in lib/libsgx_urts.so.*; do
      ln -srf lib/libsgx_urts.so $file
    done

    mv $installDir/include/ .

    mkdir -p share/
    mv $installDir/{SampleCode,licenses} share/

    mkdir -p share/bin
    mv $installDir/{environment,buildenv.mk} share/bin/
    ln -s share/bin/{environment,buildenv.mk} .

    # pkgconfig should go to lib/.
    mv $installDir/pkgconfig lib/
    ln -s lib/pkgconfig/ .

    # Also create the `sdk_libs` for compat. All the files
    # link to libraries in `lib64/`, we shouldn't link the entire
    # directory, however, as there seems to be some ambiguity between
    # SDK and PSW libraries.
    mkdir sdk_libs/
    for file in $installDir/sdk_libs/*; do
      ln -sr lib/$(basename $file) sdk_libs/
      rm $file
    done
    rmdir $installDir/sdk_libs

    # No uninstall script required.
    rm $installDir/uninstall.sh

    # Create an `sgxsdk` symlink which points to `$out` for compat.
    ln -sr . sgxsdk

    # Make sure we didn't forget any files.
    rmdir $installDir || (echo "Error: The directory $installDir still contains unhandled files: $(ls -A $installDir)" >&2 && exit 1)

    popd

    runHook postInstall
  '';

  preFixup = ''
    echo "Strip sgxsdk prefix"
    for path in "$out/share/bin/environment" "$out/bin/sgx-gdb"; do
      substituteInPlace $path --replace-fail "$TMPDIR/sgxsdk" "$out"
    done

    echo "Fixing pkg-config files"
    sed -i "s|prefix=.*|prefix=$out|g" $out/lib/pkgconfig/*.pc

    echo "Fixing SGX_SDK default in samples"
    substituteInPlace $out/share/SampleCode/LocalAttestation/buildenv.mk \
      --replace-fail '/opt/intel/sgxsdk' "$out"
    for file in $out/share/SampleCode/*/Makefile; do
      substituteInPlace $file --replace-quiet '/opt/intel/sgxsdk' "$out"
    done

    echo "Fixing BINUTILS_DIR in buildenv.mk"
    substituteInPlace $out/share/bin/buildenv.mk \
      --replace-fail 'BINUTILS_DIR ?= /usr/local/bin' \
                     'BINUTILS_DIR ?= ${BINUTILS_DIR}'

    echo "Fixing GDB path in bin/sgx-gdb"
    substituteInPlace $out/bin/sgx-gdb --replace-fail '/usr/local/bin/gdb' '${gdb}/bin/gdb'

    gdbRuntimeLibstdcxxDir=$(ldd ${gdb}/bin/gdb | sed -n 's/.*=> \(.*\)\/libstdc++.so.6 .*/\1/p')
    test -n "$gdbRuntimeLibstdcxxDir"
    substituteInPlace $out/bin/sgx-gdb \
      --replace-fail \
      '-iex "add-auto-load-safe-path /usr/lib"' \
      "-iex \"add-auto-load-safe-path /usr/lib\" -iex \"add-auto-load-safe-path /nix/store/*-gcc-*-lib\" -iex \"add-auto-load-safe-path $gdbRuntimeLibstdcxxDir\""
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgram = "${placeholder "out"}/bin/sgx_sign";
  versionCheckProgramArg = "-version";

  installCheckPhase = ''
    runHook preInstallCheck

    # Make sure all symlinks are valid.
    output=$(find "$out" -type l -exec test ! -e {} \; -print)
    if [[ -n "$output" ]]; then
      echo "Broken symlinks:"
      echo "$output"
      exit 1
    fi

    test -x "$out/bin/sgx_edger8r"

    output=$("$out/bin/sgx-gdb" -q -batch ${coreutils}/bin/true -ex run 2>&1) || {
      status=$?
      printf '%s\n' "$output"
      exit "$status"
    }
    printf '%s\n' "$output"
    if [[ "$output" == *"SyntaxWarning"* || "$output" == *"AttributeError"* || "$output" == *"warning:"* ]]; then
      echo "sgx-gdb emitted a startup warning or exception" >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  setupHook = writeText "setup-hook.sh" ''
    sgxsdk() {
        export SGX_SDK=@out@
    }

    postHooks+=(sgxsdk)
  '';

  meta = {
    homepage = "https://github.com/ATField-SGX/intel-confidentialComputing_sgx";
    maintainers = with lib.maintainers; [
      phlip9
      sbellem
      arturcygan
      veehaitch
    ];
    platforms = [ "x86_64-linux" ];
    license = [ lib.licenses.bsd3 ];
  };
})
