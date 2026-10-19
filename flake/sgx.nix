{ pkgs, llvmPackages, toolchain }:
let
  sdk = pkgs.callPackage ./sgx/intel/sdk { };
  psw = pkgs.callPackage ./sgx/intel/psw { };
  mkTrusted = mode: pkgs.callPackage ./sgx/intel/sdk/trusted-libs.nix {
    inherit (toolchain) stdenv;
    inherit llvmPackages sdk;
    inherit (toolchain) implementTools;
    llvmTools = toolchain.atfieldLlc;
    inherit mode;
  };
in
{
  inherit sdk psw;
  protect = {
    inherit sdk psw;
  };
  trusted = {
    raw = mkTrusted "raw";
    anchor = mkTrusted "anchor";
  };
}
