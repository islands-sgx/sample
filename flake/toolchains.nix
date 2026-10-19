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
  implement = import "${implementSrc}/nix/default.nix" {
    inherit pkgs implementSrc atfieldLlc;
    inherit stdenv;
  };
  enclaveCompiler = pkgs.writeShellScriptBin "enclave-clang-ir-consistent" ''
    export ATFIELD_LLC="${atfieldLlc}/bin/llc"
    export ATFIELD_NATIVE_ANCHORS="${implement.tools}/build/anchor/inject-native-anchors.ts"
    exec ${implement.tools}/bin/atfield-compile-object "${stdenv.cc}/bin/cc" "$@"
  '';
in
{
  inherit
    llvmPackages
    stdenv
    atfieldLlc
    lld
    enclaveCompiler
    ;
  implementTools = implement.tools;
  implementBundle = implement.bundle;
}
