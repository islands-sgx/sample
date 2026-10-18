{ llvmPackages, atfieldLlvmProjectSrc, runCommand }:
let
  baseMonorepo = llvmPackages.llvm.passthru.monorepoSrc;
  forkLlvmSrc = builtins.path {
    path = "${atfieldLlvmProjectSrc}/llvm";
    name = "atfield-llvm-fork-source";
  };
  src = runCommand "llvm-project-atfield" {
    inherit (baseMonorepo) passthru;
  } ''
    mkdir -p "$out"
    cp -R ${baseMonorepo}/. "$out"
    chmod -R u+w "$out"
    rm -rf "$out/llvm"
    cp -R ${forkLlvmSrc}/. "$out/llvm"
    chmod -R u+w "$out/llvm"
    cp -R "$out/polly" "$out/llvm/tools/polly"
  '';
in
llvmPackages.llvm.overrideAttrs (_: {
  pname = "llvm-atfield";
  inherit src;
  sourceRoot = "${src.name}/llvm";
})
