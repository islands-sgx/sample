{ pkgs, llvmPackages, llvmProject, implementSrc }:
let
  atfieldLlc = pkgs.callPackage ./toolchain/atfield-llc.nix {
    atfieldLlvmProjectSrc = llvmProject;
    inherit llvmPackages;
    patchelf = pkgs.patchelf;
  };
  llvmWrappedCC = llvmPackages.stdenv.cc.override {
    cc = atfieldLlc;
    bintools = llvmPackages.bintools;
  };
  stdenv = pkgs.overrideCC llvmPackages.stdenv llvmWrappedCC;
  lld = llvmPackages.lld;
  enclaveCompiler = pkgs.writeShellScriptBin "enclave-clang-ir-consistent" ''
    export ATFIELD_LLC="${atfieldLlc}/bin/llc"
    export ATFIELD_NATIVE_ANCHORS=${../scripts/inject-native-anchors.py}
    export ATFIELD_PYTHON="${pkgs.python3}/bin/python3"
    exec ${pkgs.bash}/bin/bash ${../scripts/compile-ir-object.sh} \
      "${stdenv.cc}/bin/cc" "$@"
  '';
  atfieldField = pkgs.stdenv.mkDerivation {
    pname = "atfield-field";
    version = "0.1.0";
    src = "${implementSrc}/build/field";
    nativeBuildInputs = [
      pkgs.cmake
      pkgs.ninja
    ];
    buildInputs = [
      atfieldLlc.dev
      pkgs.libxml2
      pkgs.zlib
      pkgs.zstd
    ];
    cmakeFlags = [
      "-DLLVM_DIR=${atfieldLlc.dev}/lib/cmake/llvm"
    ];
    installPhase = ''
      runHook preInstall
      install -Dm755 atfield-field "$out/bin/atfield-field"
      runHook postInstall
    '';
  };
  implementBundle = pkgs.runCommand "atfield-implement" { } ''
    cp -r ${implementSrc} "$out"
    chmod -R u+w "$out"
    mkdir -p "$out/build/field/.build-host"
    ln -sf "${atfieldField}/bin/atfield-field" "$out/build/field/.build-host/atfield-field"
    patchShebangs "$out/cli" "$out/build" "$out/host/runner"
    chmod -R a-w "$out"
  '';
in
{
  inherit
    llvmPackages
    stdenv
    atfieldLlc
    lld
    enclaveCompiler
    atfieldField
    implementBundle
    ;
}
