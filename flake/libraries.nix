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
  mlkemSrc = pkgs.fetchFromGitHub {
    owner = "pq-code-package";
    repo = "mlkem-native";
    rev = "e2d4b50896c76ada9950de2855dcd6069789e74e";
    hash = "sha256-qXiiY559VnbvOCupLggx7z0CAcyUIFx+s6MLxeitmZ0=";
  };
  mldsaSrc = pkgs.fetchFromGitHub {
    owner = "pq-code-package";
    repo = "mldsa-native";
    rev = "d7b1b6dd2081d67fef4a075e824024019f64d784";
    hash = "sha256-tfeEvCDvBFFwdLjT4ZxGjmSC5pgpMeHawJLjD9oyAGw=";
  };
  pqFlags = [
    "-m64"
    "-mno-red-zone"
    "-std=c99"
    "-O3"
    "-nostdinc"
    "-ffreestanding"
    "-fPIC"
    "-fvisibility=hidden"
    "-fno-builtin"
    "-fwrapv"
    "-fstack-protector-strong"
    "-I${toolchain.stdenv.cc}/resource-root/include"
  ];
  mlkemMode = mode: mkLibrary {
    pname = "mlkem-native-sgx-${mode}";
    version = "e2d4b50896c7";
    logicalPackage = "library/mlkem-native/e2d4b50896c7";
    inherit mode;
    src = mlkemSrc;
    sources = [ "mlkem/mlkem_native.c" ];
    archiveName = "libmlkem-native-sgx.a";
    headerName = "mlkem_native.h";
    headerSource = "mlkem/mlkem_native.h";
    extraHeaderSources = [ "mlkem/mlkem_native_config.h" ];
    compileFlags = pqFlags ++ [
      "-Imlkem"
      "-DMLK_CONFIG_PARAMETER_SET=768"
      "-DMLK_CONFIG_NO_RANDOMIZED_API"
    ];
    license = lib.licenses.asl20;
  };
  mldsaMode = mode: mkLibrary {
    pname = "mldsa-native-sgx-${mode}";
    version = "d7b1b6dd2081";
    logicalPackage = "library/mldsa-native/d7b1b6dd2081";
    inherit mode;
    src = mldsaSrc;
    sources = [ "mldsa/mldsa_native.c" ];
    archiveName = "libmldsa-native-sgx.a";
    headerName = "mldsa_native.h";
    headerSource = "mldsa/mldsa_native.h";
    extraHeaderSources = [ "mldsa/mldsa_native_config.h" ];
    compileFlags = pqFlags ++ [
      "-Imldsa"
      "-DMLD_CONFIG_PARAMETER_SET=65"
      "-DMLD_CONFIG_NO_RANDOMIZED_API"
    ];
    license = lib.licenses.asl20;
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
  mlkem = {
    raw = mlkemMode "raw";
    anchor = mlkemMode "anchor";
  };
  mldsa = {
    raw = mldsaMode "raw";
    anchor = mldsaMode "anchor";
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
