#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
  echo "usage: build-sample.sh GROUP NAME MODE" >&2
  exit 64
fi

source "$(dirname "$0")/sample.sh"
sample_setup "$1" "$2" "$3"
sample_enter_shell "$0" "$@"

export ATFIELD_SOURCE_ROOT="$source_root"

cmake_args=()
for variable in CURVE25519_DONNA_SGX_ROOT YESCRYPT_SGX_ROOT \
                QE3_SOURCE_ROOT EHSM_SOURCE_ROOT SGXWALLET_SOURCE_ROOT \
                SIGNAL_CDS_SOURCE_ROOT SGXSSL_ROOT SGX_GMP_ROOT \
                SGX_MCL_ROOT; do
  if [[ -n ${!variable:-} ]]; then
    cmake_args+=("-D${variable}=${!variable}")
  fi
done

if [[ -f "$build_dir/CMakeCache.txt" ]] &&
   ! grep -Fxq "CMAKE_C_COMPILER:FILEPATH=$ATFIELD_CC" "$build_dir/CMakeCache.txt"; then
  rm -rf "$build_dir/CMakeCache.txt" "$build_dir/CMakeFiles"
fi

cmake -S "$project_root" -B "$build_dir" -G Ninja \
  -DCMAKE_BUILD_TYPE= \
  -DCMAKE_C_COMPILER="$ATFIELD_CC" \
  -DCMAKE_CXX_COMPILER="$ATFIELD_CXX" \
  -DCMAKE_LINKER="$ATFIELD_LLD" \
  -DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=$ATFIELD_LLD" \
  -DCMAKE_AR="$ATFIELD_AR" \
  -DCMAKE_RANLIB="$ATFIELD_RANLIB" \
  -DCMAKE_C_COMPILER_AR="$ATFIELD_AR" \
  -DCMAKE_C_COMPILER_RANLIB="$ATFIELD_RANLIB" \
  -DCMAKE_CXX_COMPILER_AR="$ATFIELD_AR" \
  -DCMAKE_CXX_COMPILER_RANLIB="$ATFIELD_RANLIB" \
  -DCMAKE_NM="$ATFIELD_NM" \
  -DCMAKE_OBJCOPY="$ATFIELD_OBJCOPY" \
  -DCMAKE_READELF="$ATFIELD_READELF" \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DATFIELD_GROUP="$group" \
  -DATFIELD_SAMPLE="$name" \
  -DATFIELD_MODE="$mode" \
  -DATFIELD_LLC="$ATFIELD_LLC" \
  -DATFIELD_UPSTREAM_SOURCE_ROOT="${ATFIELD_UPSTREAM_SOURCE_ROOT:-}" \
  -DATFIELD_UPSTREAM_PACKAGE="${ATFIELD_UPSTREAM_PACKAGE:-}" \
  -DATFIELD_TEST_SIGNING_KEY="$project_root/build/test-signing-key.pem" \
  -DSGX_ENCLAVE_CLANG="$SGX_ENCLAVE_CLANG" \
  -DSGX_SDK_ROOT="$SGX_SDK_ROOT" \
  -DSGX_PSW_ROOT="$SGX_PSW_ROOT" \
  -DSGX_TRUSTED_LIB_ROOT="$SGX_TRUSTED_LIB_ROOT" \
  "${cmake_args[@]}"
cmake --build "$build_dir" --parallel
