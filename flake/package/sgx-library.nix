{
  lib,
  stdenv,
  coreutils,
  llvmTools,
  enclaveCompiler,
  sgxSdk,
}:
{
  pname,
  version,
  logicalPackage,
  mode,
  src,
  sources,
  archiveName,
  headerName,
  headerSource ? null,
  headerText ? null,
  compileFlags,
  license,
}:
assert mode == "raw" || mode == "anchor";
assert (headerSource == null) != (headerText == null);
stdenv.mkDerivation {
  inherit pname version src;
  nativeBuildInputs = [ coreutils llvmTools ];
  strictDeps = true;
  dontConfigure = true;
  dontStrip = true;
  NIX_CFLAGS_COMPILE = "";
  SOURCE_DATE_EPOCH = "1";
  ATFIELD_ANCHOR_PREPARATION = if mode == "anchor" then "1" else "0";
  ATFIELD_PAYLOAD_NAMESPACE = logicalPackage;
  ATFIELD_LLC = "${llvmTools}/bin/llc";

  buildPhase = ''
    runHook preBuild
    export ATFIELD_SOURCE_ROOT="$PWD"
    mkdir -p build
    objects=()
    compilerFlags=(${lib.escapeShellArgs compileFlags}
      -ffile-prefix-map="$PWD"=.
      -fdebug-prefix-map="$PWD"=.)
    for source in ${lib.escapeShellArgs sources}; do
      unit=$(basename "$source" .c)
      object="build/$unit.o"
      "${enclaveCompiler}/bin/enclave-clang-ir-consistent" \
        -D_LIBCPP_SGX_CONFIG "''${compilerFlags[@]}" \
        -I. -I${sgxSdk}/include -I${sgxSdk}/include/tlibc \
        -c "$source" -o "$object"
      objects+=("$object")
    done
    "${llvmTools}/bin/llvm-ar" crD "build/${archiveName}" "''${objects[@]}"
    "${llvmTools}/bin/llvm-ranlib" -D "build/${archiveName}"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0644 "build/${archiveName}" "$out/lib/${archiveName}"
    ${if headerSource != null then ''
      install -Dm0644 "${headerSource}" "$out/include/${headerName}"
    '' else ''
      cat > "build/${headerName}" <<'EOF'
${headerText}
EOF
      install -Dm0644 "build/${headerName}" "$out/include/${headerName}"
    ''}
    for licenseFile in LICENSE LICENSE.txt COPYING COPYING.txt; do
      if [[ -f "$licenseFile" ]]; then
        install -Dm0644 "$licenseFile" "$out/share/licenses/${pname}/$licenseFile"
      fi
    done
    runHook postInstall
  '';

  meta = {
    inherit license;
    platforms = [ "x86_64-linux" ];
  };
}
