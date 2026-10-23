{
  stdenv,
  lib,
  fetchurl,
  sgxSource,
  cmake,
  coreutils,
  curl,
  file,
  git,
  makeWrapper,
  ncurses,
  protobuf,
  python3,
  ocaml,
  ocamlPackages,
  which,
  debug ? false,
}:
stdenv.mkDerivation (rec {
  pname = "sgx-psw";
  # Version as given in se_version.h
  version = "2.29.100.1";
  # Version as used in the Git tag
  versionTag = "2.29";
  src = sgxSource;


  # Extract Intel-provided, pre-built enclaves and libs.
  postUnpack =
    let
      # Fetch the pre-built, Intel-signed Architectural Enclaves (AE). They help
      # run user application enclaves, verify launch policies, produce remote
      # attestation quotes, and do platform certification.
      ae.prebuilt = fetchurl {
        url = "https://download.01.org/intel-sgx/sgx-linux/${versionTag}/prebuilt_ae_${versionTag}.tar.gz";
        sha256 = "091icxpqi69722cb31blb7n3v9fgi82g07cxrdv6kjhfnvm7sn0y";
      };

      # Pre-built ipp-crypto with mitigations.
      optlib.prebuilt = fetchurl {
        url = "https://download.01.org/intel-sgx/sgx-linux/${versionTag}/optimized_libs_${versionTag}.tar.gz";
        sha256 = "065aa4dpa3mriwp8fp2gjrwfykysi5azhvx18g3h4fb9pdld6q7f";
      };

      # Fetch the Data Center Attestation Primitives (DCAP) platform enclaves
      # and pre-built sgxssl.
      dcap = rec {
        version = "1.26";
        filename = "prebuilt_dcap_${version}.tar.gz";
        prebuilt = fetchurl {
          url = "https://download.01.org/intel-sgx/sgx-dcap/${version}/linux/${filename}";
          hash = "sha256-TXQ8xh0q9RKPyKqjMvxoQtIH2lxbhCiwpV+HvQxACaw=";
        };
      };
    in
    ''
      tar -xzvf ${ae.prebuilt}     -C $sourceRoot/
      tar -xzvf ${optlib.prebuilt} -C $sourceRoot/

      # Make sure we use the correct version of prebuilt DCAP.
      grep -q '^dcap_version=${dcap.version}$' "$src/external/dcap_source/QuoteGeneration/download_prebuilt.sh" \
        || (echo "Could not find expected prebuilt DCAP ${dcap.filename}" >&2 && exit 1)

      tar -xzvf ${dcap.prebuilt} -C $sourceRoot/external/dcap_source prebuilt/
      tar -xzvf ${dcap.prebuilt} -C $sourceRoot/external/dcap_source/QuoteGeneration psw/
    '';

  postPatch =
    let
      # The base directories we want to copy headers from. The exact headers are
      # parsed from <linux/installer/common/sdk/BOMs/sdk_base.txt>
      bomDirsToCopyFrom = builtins.concatStringsSep "|" [
        "common/"
        "external/dcap_source/"
        "external/ippcp_internal/"
        "external/sgx-emm/"
        "psw/"
        "sdk/tlibcxx/"
      ];
    in
    ''
      patchShebangs \
        external/sgx-emm/create_symlink.sh \
        linux/installer/bin/build-installpkg.sh \
        linux/installer/common/psw/createTarball.sh \
        linux/installer/common/psw/install.sh

      # Run sgx-sdk preparation step
      make ATFIELD_OFFLINE_PREPARATION=1 preparation

      # Build a fake SGX_SDK directory. Normally sgx-psw depends on first building
      # all of sgx-sdk, however we can actually build them independently by just
      # copying a few header files and building `sgx_edger8r` separately.
      mkdir .sgxsdk
      export SGX_SDK="$(readlink -f .sgxsdk)"

      # Parse the BOM for the headers we need, then copy them into SGX_SDK
      # Each line in the BOM.txt looks like:
      # <deliverydir>/...\t<installdir>/package/...\t....
      # TODO(phlip9): hardlink?
      sed -n -r 's:^<deliverydir>/(${bomDirsToCopyFrom})(\S+)\s<installdir>/package/(\S+)\s.*$:\1\2\n.sgxsdk/\3:p' \
        < linux/installer/common/sdk/BOMs/sdk_base.txt \
        | xargs --max-args=2 install -v -D

      # Update edger8r sources for OCaml 5 compatibility.
      sed -i 's/let failwithf fmt = kprintf failwith fmt;;/let failwithf fmt = ksprintf failwith fmt;;/' \
        sdk/edger8r/linux/Util.ml
      sed -i '/| Ast\.PTPtr(atype, _) -> is_foreign_atype atype/{n;/| _                   -> (false, "")/d;}' \
        sdk/edger8r/linux/CodeGen.ml

      # Ensure ocamlbuild uses Nix-provided ocaml toolchain, not host /usr.
      ocamlcPath="${ocaml}/bin/ocamlc"
      ocamloptPath="${ocaml}/bin/ocamlopt"
      ocamllibPath="${ocaml}/lib/ocaml"
      sed -i -E "s#(^[[:space:]]*)ocamlbuild[[:space:]]+#\\1OCAMLC=$ocamlcPath OCAMLOPT=$ocamloptPath OCAMLLIB=$ocamllibPath ocamlbuild #g" \
        sdk/edger8r/linux/Makefile
      sed -i -E "s#(ocamlbuild)([[:space:]]+)#\\1 -ocamlc $ocamlcPath -ocamlopt $ocamloptPath \\2#g" sdk/edger8r/linux/Makefile
    '';

  nativeBuildInputs = [
    cmake
    file
    git
    makeWrapper
    ncurses
    ocaml
    ocamlPackages.ocamlbuild
    python3
    which
  ];

  buildInputs = [
    curl
    protobuf
  ];

  hardeningDisable = [ "zerocallusedregs" ];
  NIX_CFLAGS_COMPILE = "-Wno-deprecated-declarations -Wno-unused-result";

  dontUseCmakeConfigure = true;
  enableParallelBuilding = true;

  preBuild = ''
    # Build `sgx_edger8r`, the enclave .edl -> .h file codegen tool.
    # Then place it in `$SGX_SDK/bin` and `$SGX_SDK/bin/x64`.
    make -C sdk/edger8r/linux
    mkdir -p $SGX_SDK/bin/x64
    sgx_edger8r_bin="$(readlink -f build/linux/sgx_edger8r)"
    ln -s $sgx_edger8r_bin $SGX_SDK/bin/
    ln -s $sgx_edger8r_bin $SGX_SDK/bin/x64/

    # Add this so we can link against libsgx_urts.
    build_dir="$(readlink -f build/linux)"
    ln -s $build_dir $SGX_SDK/lib
    ln -s $build_dir $SGX_SDK/lib64
  '';

  buildFlags = [
    "psw_install_pkg"
    "ATFIELD_REPRODUCIBLE_ARCHIVES=1"
  ]
  ++ lib.optionals debug [ "DEBUG=1" ];

  installFlags = [
    "-C linux/installer/common/psw/output"
    "DESTDIR=$(TMPDIR)/install"
  ];

  postInstall = ''
    installDir=$TMPDIR/install
    sgxPswDir=$installDir/opt/intel/sgxpsw

    mv $installDir/usr/lib64/ $out/lib/
    ln -sr $out/lib $out/lib64

    # Install udev rules to lib/udev/rules.d
    mv $sgxPswDir/udev/ $out/lib/

    # Install example AESM config
    mkdir $out/etc/
    mv $sgxPswDir/aesm/conf/aesmd.conf $out/etc/
    rmdir $sgxPswDir/aesm/conf/

    # Delete init service
    rm $sgxPswDir/aesm/aesmd.conf

    # Move systemd services
    mkdir -p $out/lib/systemd/system/
    mv $sgxPswDir/aesm/aesmd.service $out/lib/systemd/system/
    mv $sgxPswDir/remount-dev-exec.service $out/lib/systemd/system/

    # Move misc files
    mkdir $out/share/
    mv $sgxPswDir/licenses $out/share/

    # Remove unnecessary files
    rm $sgxPswDir/{cleanup.sh,startup.sh}
    rm -r $sgxPswDir/scripts

    # Move aesmd binaries/libraries/enclaves
    mv $sgxPswDir/aesm/ $out/

    # We absolutely MUST avoid stripping or patching these ".signed.so" SGX
    # enclaves. Stripping would change each enclave measurement (hash of the
    # binary).
    #
    # We're going to temporarily move these enclave libs to another directory
    # until after stripping/patching in the fixupPhase.
    mkdir $TMPDIR/enclaves
    mv $out/aesm/*.signed.so* $TMPDIR/enclaves

    mkdir $out/bin
    makeWrapper $out/aesm/aesm_service $out/bin/aesm_service \
      --suffix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ protobuf ]}:$out/aesm \
      --chdir "$out/aesm"

    # Make sure we didn't forget to handle any files
    rmdir $sgxPswDir || (echo "Error: The directory $installDir still contains unhandled files: $(ls -A $installDir)" >&2 && exit 1)
  '';

  stripDebugList = [
    "lib"
    "bin"
    # Also strip binaries/libs in the `aesm` directory
    "aesm"
  ];

  postFixup = ''
    # Move the SGX enclaves back after everything else has been stripped.
    mv $TMPDIR/enclaves/*.signed.so* $out/aesm/
    rmdir $TMPDIR/enclaves

    # Fixup the aesmd systemd service
    #
    # Most—if not all—of those fixups are not relevant for NixOS as we have our own
    # NixOS module which is based on those files without relying on them. Still, it
    # is helpful to have properly patched versions for non-NixOS distributions.
    echo "Fixing aesmd.service"
    substituteInPlace $out/lib/systemd/system/aesmd.service \
      --replace-fail '@aesm_folder@' \
                     "$out/aesm" \
      --replace-fail 'Type=forking' \
                     'Type=simple' \
      --replace-fail "ExecStart=$out/aesm/aesm_service" \
                     "ExecStart=$out/bin/aesm_service --no-daemon"\
      --replace-fail "/bin/mkdir" \
                     "${coreutils}/bin/mkdir" \
      --replace-fail "/bin/chown" \
                     "${coreutils}/bin/chown" \
      --replace-fail "/bin/chmod" \
                     "${coreutils}/bin/chmod" \
      --replace-fail "/bin/kill" \
                     "${coreutils}/bin/kill"
  '';

  doInstallCheck = true;

  installCheckPhase = ''
    runHook preInstallCheck

    test -x "$out/bin/aesm_service"
    test -e "$out/lib/libsgx_enclave_common.so"

    runHook postInstallCheck
  '';

  meta = {
    homepage = "https://github.com/ATField-SGX/intel-confidentialComputing_sgx";
    maintainers = with lib.maintainers; [
      phlip9
      veehaitch
      citadelcore
    ];
    platforms = [ "x86_64-linux" ];
    license = [ lib.licenses.bsd3 ];
  };
})
