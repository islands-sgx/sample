{ pkgs, llvmPackages, llvmProject }:
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
in
{
  inherit llvmPackages stdenv atfieldLlc lld enclaveCompiler;
}
