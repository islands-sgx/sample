{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.llvm-project.url = "github:islands-sgx/llvm-llvmProject/generic-anchor";
  inputs.llvm-project.flake = false;

  inputs.implement = {
    url = "git+ssh://git@github.com/islands-sgx/implement";
    flake = false;
  };

  outputs =
    inputs:
    let
      system = "x86_64-linux";
      pkgs = import inputs.nixpkgs { inherit system; };
      lib = pkgs.lib;
      llvmPackages = pkgs.llvmPackages_22;
      toolchain = import ./flake/toolchains.nix {
        inherit pkgs llvmPackages;
        llvmProject = inputs."llvm-project";
        implementSrc = inputs.implement;
      };
      sgx = import ./flake/sgx.nix {
        inherit pkgs llvmPackages toolchain;
      };
      libraries = import ./flake/libraries.nix {
        inherit pkgs toolchain sgx;
      };
      application = import ./flake/application.nix {
        inherit pkgs toolchain sgx;
      };
      anchorNames = [
        "curve25519-donna"
        "fiat-p384"
        "sqlite"
        "yescrypt"
      ];
      applicationNames = [
        "ehsm"
        "ehsm-opt-1"
        "ehsm-opt-2"
        "qe3"
        "sgxwallet"
        "signal-cds"
      ];
      opensslMicroNames = [
        "openssl-aes-256-gcm-1k"
        "openssl-sha256-4k"
      ];
      pqMicroNames = [ "mlkem-768" "mldsa-65" ];
      microNames = [
        "yescrypt-kdf-rw"
        "wolfssl-pbkdf2-sha256"
      ] ++ opensslMicroNames ++ pqMicroNames;
      anchorModes = [ "raw" "anchor" ];
      benchModes = [ "raw" "anchor" "protect" "protect-naive" ];
      benchSamples = {
        micro = microNames;
        application = applicationNames;
      };
      sourceEnv = {
        qe3 = {
          QE3_SOURCE_ROOT = "${application.sources.qe3}";
        };
        ehsm = {
          EHSM_SOURCE_ROOT = "${application.sources.ehsm}";
        };
        ehsm-opt-1 = {
          EHSM_SOURCE_ROOT = "${application.sources.ehsmOpt1}";
        };
        ehsm-opt-2 = {
          EHSM_SOURCE_ROOT = "${application.sources.ehsmOpt2}";
        };
        sgxwallet = {
          SGXWALLET_SOURCE_ROOT = "${application.sources.sgxwallet}";
        };
        signal-cds = {
          SIGNAL_CDS_SOURCE_ROOT = "${application.sources.signalCds}";
        };
      };
      mkSampleShell =
        group: name: mode:
        let
          protectMode = mode == "protect" || mode == "protect-naive";
          cmakeMode = if protectMode then "protect" else mode;
          worksetPolicy = if mode == "protect-naive" then "naive" else "dynamic";
          libraryMode = if protectMode then "anchor" else mode;
          sampleSgx = if protectMode then sgx.protect else sgx;
          sampleLibraries =
            if group == "anchor" && name == "curve25519-donna" then
              [ libraries."curve25519-donna".${libraryMode} ]
            else if (group == "anchor" && name == "yescrypt") || (group == "bench/micro" && name == "yescrypt-kdf-rw") then
              [ libraries.yescrypt.${libraryMode} ]
            else if group == "bench/micro" && name == "wolfssl-pbkdf2-sha256" then
              [ libraries.wolfssl.${libraryMode} ]
            else if group == "bench/micro" && name == "mlkem-768" then
              [ libraries.mlkem.${libraryMode} ]
            else if group == "bench/micro" && name == "mldsa-65" then
              [ libraries.mldsa.${libraryMode} ]
            else if group == "bench/micro" && lib.elem name opensslMicroNames then
              [ application.libraries.sgxssl.${libraryMode} ]
            else if group == "bench/application" && (lib.hasPrefix "ehsm" name) then
              [ application.libraries.sgxssl.${libraryMode} ]
            else if group == "bench/application" && name == "sgxwallet" then
              [
                application.libraries.gmp.${libraryMode}
                application.libraries.mcl.${libraryMode}
              ]
            else
              [ ];
          runtimeLibraries = [
            pkgs.openssl
            pkgs.stdenv.cc.cc.lib
            pkgs.zlib
            sampleSgx.psw
          ];
          implementRoot = "${toolchain.implementBundle}";
          protectPackages = lib.optionals protectMode [
            toolchain.implementBundle
          ];
          acquisitionPackages = lib.optionals (mode == "protect") [
            toolchain.implementAcquisition
          ];
          implementRuntime = if protectMode || group != "anchor" then
            toolchain.implementBundle
          else
            toolchain.implementTools;
          protectEnv = lib.optionalAttrs protectMode {
            ATFIELD_FIELD_TOOL = "${implementRoot}/bin/atfield-field";
          };
        in
        (pkgs.mkShell.override { stdenv = toolchain.stdenv; }) {
          packages = [
            pkgs.bun
            pkgs.cmake
            pkgs.coreutils
            pkgs.ninja
            pkgs.openssl
            sampleSgx.psw
            sampleSgx.sdk
            sgx.trusted.${libraryMode}
            toolchain.stdenv.cc
            toolchain.atfieldLlc
            toolchain.lld
          ]
          ++ lib.optionals (!protectMode) [
            toolchain.enclaveCompiler
            toolchain.implementTools
          ]
          ++ protectPackages
          ++ acquisitionPackages
          ++ sampleLibraries;
          env = {
            ATFIELD_ANCHOR_PREPARATION = if mode == "raw" then "0" else "1";
            ATFIELD_FIELD_BOUNDARY = if protectMode then "1" else "0";
            ATFIELD_CMAKE_MODULE = "${implementRuntime}/cmake/SgxEnclave.cmake";
            ATFIELD_IMPLEMENT_ROOT = "${implementRuntime}";
            ATFIELD_AR = "${toolchain.atfieldLlc}/bin/llvm-ar";
            ATFIELD_CC = "${toolchain.stdenv.cc}/bin/cc";
            ATFIELD_CXX = "${toolchain.stdenv.cc}/bin/c++";
            ATFIELD_LLC = "${toolchain.atfieldLlc}/bin/llc";
            ATFIELD_LLD = "${toolchain.lld}/bin/ld.lld";
            ATFIELD_MODE = cmakeMode;
            ATFIELD_NATIVE_ANCHORS = "${implementRuntime}/build/anchor/inject-native-anchors.ts";
            ATFIELD_NM = "${toolchain.atfieldLlc}/bin/llvm-nm";
            ATFIELD_OBJCOPY = "${toolchain.atfieldLlc}/bin/llvm-objcopy";
            ATFIELD_PAYLOAD_NAMESPACE = "${group}/${name}";
            ATFIELD_RANLIB = "${toolchain.atfieldLlc}/bin/llvm-ranlib";
            ATFIELD_READELF = "${toolchain.atfieldLlc}/bin/llvm-readelf";
            ATFIELD_SAMPLE_SHELL = "${group}/${name}/${mode}";
            ATFIELD_IMPLEMENT_TOOLS = "${implementRuntime}";
            LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibraries;
            SGX_ARCH = "x64";
            SGX_ENCLAVE_CLANG =
              if protectMode then
                "${implementRoot}/bin/atfield-enclave-clang"
              else
                "${toolchain.enclaveCompiler}/bin/enclave-clang-ir-consistent";
            SGX_MODE = "HW";
            SGX_PSW_ROOT = "${sampleSgx.psw}";
            SGX_SDK_ROOT = "${sampleSgx.sdk}";
            SGX_TRUSTED_LIB_ROOT = "${sgx.trusted.${libraryMode}}";
          }
          // lib.optionalAttrs (group == "anchor" && name == "curve25519-donna") {
            CURVE25519_DONNA_SGX_ROOT = "${builtins.head sampleLibraries}";
          }
          // lib.optionalAttrs ((group == "anchor" && name == "yescrypt") || (group == "bench/micro" && name == "yescrypt-kdf-rw")) {
            YESCRYPT_SGX_ROOT = "${builtins.head sampleLibraries}";
          }
          // lib.optionalAttrs (group == "bench/micro" && name == "wolfssl-pbkdf2-sha256") {
            WOLFSSL_SGX_ROOT = "${builtins.head sampleLibraries}";
          }
          // lib.optionalAttrs (group == "bench/micro" && name == "mlkem-768") {
            MLKEM_SGX_ROOT = "${builtins.head sampleLibraries}";
          }
          // lib.optionalAttrs (group == "bench/micro" && name == "mldsa-65") {
            MLDSA_SGX_ROOT = "${builtins.head sampleLibraries}";
          }
          // lib.optionalAttrs (group == "bench/micro" && lib.elem name opensslMicroNames) {
            SGXSSL_ROOT = "${application.libraries.sgxssl.${libraryMode}}";
          }
          // lib.optionalAttrs (group == "bench/application" && (lib.hasPrefix "ehsm" name)) {
            SGXSSL_ROOT = "${application.libraries.sgxssl.${libraryMode}}";
          }
          // lib.optionalAttrs (group == "bench/application" && name == "sgxwallet") {
            SGX_GMP_ROOT = "${application.libraries.gmp.${libraryMode}}";
            SGX_MCL_ROOT = "${application.libraries.mcl.${libraryMode}}";
          }
          // protectEnv
          // lib.optionalAttrs protectMode {
            ATFIELD_WORKSET_POLICY = worksetPolicy;
          }
          // lib.optionalAttrs (group == "bench/application") sourceEnv.${name};
        };
      sampleShells = lib.listToAttrs (
        lib.concatMap (
          name:
          map (mode: lib.nameValuePair "anchor-${name}-${mode}" (mkSampleShell "anchor" name mode)) anchorModes
        ) anchorNames
        ++ lib.concatMap (
          scale:
          lib.concatMap (
            name:
            map (mode: lib.nameValuePair "bench-${scale}-${name}-${mode}" (mkSampleShell "bench/${scale}" name mode)) benchModes
          ) benchSamples.${scale}
        ) [ "micro" "application" ]
      );
      packageOutputs = {
        atfield-acquisition = toolchain.implementAcquisition;
        atfield-bundle = toolchain.implementBundle;
        atfield-llc = toolchain.atfieldLlc;
        atfield-tools = toolchain.implementTools;
        curve25519-donna-sgx-anchor = libraries."curve25519-donna".anchor;
        curve25519-donna-sgx-raw = libraries."curve25519-donna".raw;
        enclave-clang = toolchain.enclaveCompiler;
        intel-sgx-gmp-anchor = application.libraries.gmp.anchor;
        intel-sgx-gmp-raw = application.libraries.gmp.raw;
        intel-sgx-ssl-anchor = application.libraries.sgxssl.anchor;
        intel-sgx-ssl-raw = application.libraries.sgxssl.raw;
        lld = toolchain.lld;
        mlkem-native-sgx-anchor = libraries.mlkem.anchor;
        mlkem-native-sgx-raw = libraries.mlkem.raw;
        mldsa-native-sgx-anchor = libraries.mldsa.anchor;
        mldsa-native-sgx-raw = libraries.mldsa.raw;
        mcl-sgx-anchor = application.libraries.mcl.anchor;
        mcl-sgx-raw = application.libraries.mcl.raw;
        sgx-psw = sgx.psw;
        sgx-psw-readiness = sgx.protect.psw;
        sgx-sdk = sgx.sdk;
        sgx-sdk-readiness = sgx.protect.sdk;
        sgx-trusted-anchor = sgx.trusted.anchor;
        sgx-trusted-raw = sgx.trusted.raw;
        yescrypt-sgx-anchor = libraries.yescrypt.anchor;
        yescrypt-sgx-raw = libraries.yescrypt.raw;
        wolfssl-sgx-anchor = libraries.wolfssl.anchor;
        wolfssl-sgx-raw = libraries.wolfssl.raw;
      };
    in
    {
      packages.${system} = packageOutputs;
      devShells.${system} = {
        default = pkgs.mkShell {
          packages = [
            pkgs.bun
            pkgs.cmake
            pkgs.just
            pkgs.ninja
          ];
        };
      }
      // sampleShells;
    };
}
