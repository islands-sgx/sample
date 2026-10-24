{ pkgs, toolchain, sgx }:
let
  sgxSources = import ./application-sources.nix { inherit pkgs; };
  sgxSsl = mode: pkgs.callPackage ./package/sgxssl.nix {
    inherit (toolchain) stdenv;
    llvmTools = toolchain.atfieldLlc;
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
    implementTools = toolchain.implementTools;
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
      patches = [ ../bench/application/signal-cds/patches/clang.patch ];
    };
    ehsm = pkgs.applyPatches {
      name = "${sgxSources.ehsm.name}-clang";
      src = sgxSources.ehsm;
      patches = [
        ../bench/application/ehsm/patches/clang.patch
        ../bench/application/ehsm/patches/bounds.patch
      ];
    };
    ehsmOpt1 = pkgs.applyPatches {
      name = "${sgxSources.ehsm.name}-opt-1-clang";
      src = sgxSources.ehsm;
      patches = [
        ../bench/application/ehsm-opt-1/patches/clang.patch
        ../bench/application/ehsm-opt-1/patches/bounds.patch
      ];
    };
    ehsmOpt2 = pkgs.applyPatches {
      name = "${sgxSources.ehsm.name}-opt-2-clang";
      src = sgxSources.ehsm;
      patches = [
        ../bench/application/ehsm-opt-2/patches/clang.patch
        ../bench/application/ehsm-opt-2/patches/bounds.patch
      ];
    };
    sgxwallet = pkgs.applyPatches {
      name = "${sgxSources.sgxwallet.name}-clang";
      src = sgxSources.sgxwallet;
      patches = [
        ../bench/application/sgxwallet/patches/clang.patch
        ../bench/application/sgxwallet/patches/bounds.patch
      ];
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
