{ pkgs, toolchain, sgx }:
let
  inherit (pkgs) lib;
  mkLibrary = pkgs.callPackage ./package/sgx-library.nix {
    inherit (toolchain) stdenv;
    llvmTools = toolchain.atfieldLlc;
    enclaveCompiler = toolchain.enclaveCompiler;
    sgxSdk = sgx.sdk;
  };
  curveSrc = pkgs.fetchFromGitHub {
    owner = "agl";
    repo = "curve25519-donna";
    rev = "1.3";
    hash = "sha256-o5Nae+9Bh5ogn02yx5BcZVHtTfxTEYe7cVgouYMpd74=";
  };
  yescryptSrc = pkgs.fetchurl {
    url = "https://www.openwall.com/yescrypt/yescrypt-1.1.0.tar.gz";
    hash = "sha256-hdDNfTh6Q77VXriWyEzeD6Na5cFpcGCCyUrkcX9mxww=";
  };
  curveMode = mode: mkLibrary {
    pname = "curve25519-donna-sgx-${mode}";
    version = "1.3";
    logicalPackage = "library/curve25519-donna/1.3";
    inherit mode;
    src = curveSrc;
    sources = [ "curve25519-donna.c" ];
    archiveName = "libcurve25519-donna-sgx.a";
    headerName = "curve25519-donna.h";
    headerText = ''
      #ifndef CURVE25519_DONNA_H
      #define CURVE25519_DONNA_H

      #include <stdint.h>

      int curve25519_donna(uint8_t *mypublic, const uint8_t *secret,
                           const uint8_t *basepoint);

      #endif
    '';
    compileFlags = [
      "-m64"
      "-mno-red-zone"
      "-std=c99"
      "-O3"
      "-nostdinc"
      "-fPIC"
      "-fvisibility=hidden"
      "-fno-builtin"
      "-ffreestanding"
      "-fwrapv"
      "-fstack-protector-strong"
      "-fzero-call-used-regs=used-gpr"
      "-Wformat"
      "-Wformat-security"
      "-Werror=format-security"
      "-I${toolchain.stdenv.cc}/resource-root/include"
    ];
    license = lib.licenses.bsd3;
  };
  yescryptMode = mode: mkLibrary {
    pname = "yescrypt-sgx-${mode}";
    version = "1.1.0";
    logicalPackage = "library/yescrypt/1.1.0";
    inherit mode;
    src = yescryptSrc;
    sources = [
      "yescrypt-opt.c"
      "yescrypt-common.c"
      "sha256.c"
      "insecure_memzero.c"
    ];
    archiveName = "libyescrypt-sgx.a";
    headerName = "yescrypt.h";
    headerSource = "yescrypt.h";
    compileFlags = [
      "-m64"
      "-mno-red-zone"
      "-std=c99"
      "-mavx"
      "-O0"
      "-nostdinc"
      "-ffreestanding"
      "-fvisibility=hidden"
      "-fpie"
      "-fno-strict-aliasing"
      "-fwrapv"
      "-fno-delete-null-pointer-checks"
      "-fzero-call-used-regs=used-gpr"
      "-fstack-protector-strong"
      "-ftrivial-auto-var-init=pattern"
      "-Wformat"
      "-Wformat-security"
      "-Werror=format-security"
      "-fno-builtin-printf"
      "-ffunction-sections"
      "-fdata-sections"
      "-U__unix__"
      "-U__linux__"
      "-I${toolchain.stdenv.cc}/resource-root/include"
    ];
    license = lib.licenses.bsd2;
  };
in
{
  "curve25519-donna" = {
    raw = curveMode "raw";
    anchor = curveMode "anchor";
  };
  yescrypt = {
    raw = yescryptMode "raw";
    anchor = yescryptMode "anchor";
  };
  wolfssl = {
    raw = pkgs.callPackage ./package/wolfssl.nix {
      inherit (toolchain) stdenv;
      llvmTools = toolchain.atfieldLlc;
      enclaveCompiler = toolchain.enclaveCompiler;
      sgxSdk = sgx.sdk;
      mode = "raw";
    };
    anchor = pkgs.callPackage ./package/wolfssl.nix {
      inherit (toolchain) stdenv;
      llvmTools = toolchain.atfieldLlc;
      enclaveCompiler = toolchain.enclaveCompiler;
      sgxSdk = sgx.sdk;
      mode = "anchor";
    };
  };
}
