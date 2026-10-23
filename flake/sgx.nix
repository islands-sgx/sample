{ pkgs, llvmPackages, toolchain, sgxSource }:
let
  sdkBase = pkgs.callPackage ./sgx/intel/sdk { inherit sgxSource; };
  sgxEdger8rAbi = pkgs.stdenv.mkDerivation {
    pname = "sgx-edger8r-abi";
    version = "2.29.100.1";
    src = pkgs.fetchFromGitHub {
      owner = "islands-sgx";
      repo = "intel-confidentialComputing_sgx";
      rev = "273078fca21a0620c8f74fe9fcd69c62dcc817d0";
      sha256 = "194frzwd92zv089d50zjp7d14ssf4dp101w1jmdd99rds5h594fl";
    };
    sourceRoot = "source/sdk/edger8r/linux";
    nativeBuildInputs = [ pkgs.ocaml pkgs.ocamlPackages.ocamlbuild pkgs.which ];
    postPatch = ''
      sed -i 's/let failwithf fmt = kprintf failwith fmt;;/let failwithf fmt = ksprintf failwith fmt;;/' Util.ml
      sed -i '/| Ast\.PTPtr(atype, _) -> is_foreign_atype atype/{n;/| _                   -> (false, "")/d;}' CodeGen.ml
    '';
    buildPhase = ''
      ocamlbuild -ocamlc ${pkgs.ocaml}/bin/ocamlc -ocamlopt ${pkgs.ocaml}/bin/ocamlopt -cflags -ccopt,-fpie,-ccopt,-fcf-protection -lflags -runtime-variant,_pic,-ccopt,-pie,-ccopt -lflag "-Wl,-z,relro,-z,now,-z,noexecstack" -no-links -libs str,unix Edger8r.native
    '';
    installPhase = ''
      install -Dm0755 _build/Edger8r.native $out/bin/sgx_edger8r
    '';
  };
  sdk = pkgs.runCommand "sgx-sdk-2.29.100.1" {
    passthru = { inherit (sdkBase) version src; };
  } ''
    mkdir -p $out/bin/x64
    for item in include lib lib64 sdk_libs share sgxsdk environment buildenv.mk pkgconfig; do
      if [ -e "${sdkBase}/$item" ]; then
        ln -s "${sdkBase}/$item" "$out/$item"
      fi
    done
    for f in "${sdkBase}"/bin/*; do
      b=$(basename "$f")
      if [ "$b" = "x64" ] || [ "$b" = "sgx_edger8r" ]; then continue; fi
      ln -s "$f" "$out/bin/$b"
      ln -sr "$out/bin/$b" "$out/bin/x64/$b"
    done
    ln -s "${sgxEdger8rAbi}/bin/sgx_edger8r" "$out/bin/sgx_edger8r"
    ln -sr "$out/bin/sgx_edger8r" "$out/bin/x64/sgx_edger8r"
  '';
  psw = pkgs.callPackage ./sgx/intel/psw { inherit sgxSource; };
  mkTrusted = mode: pkgs.callPackage ./sgx/intel/sdk/trusted-libs.nix {
    inherit (toolchain) stdenv;
    inherit llvmPackages;
    sdk = sdkBase;
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
