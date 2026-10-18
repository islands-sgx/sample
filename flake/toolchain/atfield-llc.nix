{ llvmPackages, atfieldLlvmProjectSrc, runCommand, patchelf, makeWrapper }:
let
  atfieldLLVM = import ./atfield-llvm.nix {
    inherit llvmPackages atfieldLlvmProjectSrc runCommand;
  };
in
atfieldLLVM.overrideAttrs (old: {
  pname = "llvm-atfield-llc";
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DLLVM_ENABLE_PROJECTS=clang"
    "-DLLVM_BUILD_TESTS=OFF"
    "-DLLVM_INCLUDE_TESTS=OFF"
    "-DLLVM_BUILD_EXAMPLES=OFF"
    "-DLLVM_INCLUDE_EXAMPLES=OFF"
    "-DLLVM_BUILD_UTILS=OFF"
    "-DLLVM_INCLUDE_UTILS=OFF"
    "-DLLVM_BUILD_TOOLS=ON"
    "-DLLVM_TOOL_POLLY_BUILD=OFF"
    "-DCLANG_BUILD_TOOLS=ON"
    "-DCLANG_INCLUDE_TESTS=OFF"
    "-DLLVM_TOOL_LLC_BUILD=ON"
    "-DLLVM_TOOL_LLVM_MC_BUILD=ON"
  ];
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ patchelf makeWrapper ];
  postFixup = (old.postFixup or "") + ''
    for tool in \
      "$out/bin/clang" \
      "$out/bin/clang++" \
      "$out/bin/clang-scan-deps"
    do
      ${patchelf}/bin/patchelf --add-rpath "${placeholder "out"}/lib:${placeholder "lib"}/lib" "$tool"
    done
    makeWrapper "$out/bin/clang" "$out/bin/cc" \
      --add-flags "-B${llvmPackages.bintools}/bin"
    makeWrapper "$out/bin/clang++" "$out/bin/c++" \
      --add-flags "-B${llvmPackages.bintools}/bin"
  '';
  doCheck = false;
})
