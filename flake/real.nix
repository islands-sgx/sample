{ pkgs, toolchain, sgx }:
let
  sgxSources = import ./real-sources.nix { inherit pkgs; };
  sgxSsl = mode: pkgs.callPackage ./package/sgxssl.nix {
    inherit (toolchain) stdenv;
    llvmTools = toolchain.atfieldLlc;
    enclaveCompiler = toolchain.enclaveCompiler;
    implementTools = toolchain.implementTools;
    sgxSdk = sgx.sdk;
    inherit mode;
  };
  sgxGmp = mode: pkgs.callPackage ./package/sgx-gmp.nix {
    inherit (toolchain) stdenv;
    coreutils = pkgs.coreutils;
    gnumake = pkgs.gnumake;
    m4 = pkgs.m4;
    llvmTools = toolchain.atfieldLlc;
    enclaveCompiler = toolchain.enclaveCompiler;
    sgxSdk = sgx.sdk;
    walletSource = sgxSources.sgxwallet;
    inherit mode;
  };
  mcl = mode: pkgs.callPackage ./package/sgx-mcl.nix {
    inherit (toolchain) stdenv;
    coreutils = pkgs.coreutils;
    gnumake = pkgs.gnumake;
    python3 = pkgs.python3;
    llvmTools = toolchain.atfieldLlc;
    enclaveCompiler = toolchain.enclaveCompiler;
    implementTools = toolchain.implementTools;
    sgxSdk = sgx.sdk;
    inherit mode;
  };
in
{
  sources = sgxSources // {
    signalCds = pkgs.applyPatches {
      name = "${sgxSources.signalCds.name}-clang";
      src = sgxSources.signalCds;
      patches = [ ../real/signal-cds/patches/clang.patch ];
    };
    ehsm = pkgs.applyPatches {
      name = "${sgxSources.ehsm.name}-clang";
      src = sgxSources.ehsm;
      patches = [ ../real/ehsm/patches/clang.patch ];
    };
    sgxwallet = pkgs.applyPatches {
      name = "${sgxSources.sgxwallet.name}-clang";
      src = sgxSources.sgxwallet;
      patches = [ ../real/sgxwallet/patches/clang.patch ];
    };
  };
  libraries = {
    sgxssl = {
      raw = sgxSsl "raw";
      anchor = sgxSsl "anchor";
    };
    gmp = {
      raw = sgxGmp "raw";
      anchor = sgxGmp "anchor";
    };
    mcl = {
      raw = mcl "raw";
      anchor = mcl "anchor";
    };
  };
}
