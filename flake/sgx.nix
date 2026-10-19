{ pkgs, llvmPackages, toolchain, readinessSource }:
let
  sdk = pkgs.callPackage ./sgx/intel/sdk { };
  psw = pkgs.callPackage ./sgx/intel/psw { };
  sdkReadiness = pkgs.callPackage ./sgx/intel/sdk {
    readinessPatch = "${readinessSource}/patches/sdk-readiness.patch";
  };
  pswReadiness = pkgs.callPackage ./sgx/intel/psw {
    readinessPatch = "${readinessSource}/patches/psw-readiness.patch";
  };
  mkTrusted = mode: pkgs.callPackage ./sgx/intel/sdk/trusted-libs.nix {
    inherit (toolchain) stdenv;
    inherit llvmPackages sdk;
    llvmTools = toolchain.atfieldLlc;
    inherit mode;
  };
in
{
  inherit sdk psw;
  protect = {
    sdk = sdkReadiness;
    psw = pswReadiness;
  };
  trusted = {
    raw = mkTrusted "raw";
    anchor = mkTrusted "anchor";
  };
}
