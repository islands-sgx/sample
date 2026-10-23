include_guard(GLOBAL)
include("${CMAKE_SOURCE_DIR}/bench/micro/common/BenchSample.cmake")

find_path(
  SGXSSL_ROOT
  NAMES include/openssl/aes.h
  HINTS ENV SGXSSL_ROOT
  NO_DEFAULT_PATH
  REQUIRED)

function(bench_add_openssl_sample name)
  bench_add_sample(
    NAME "${name}"
    HOST_SOURCES answer.c
    INCLUDE_DIRECTORIES "${SGXSSL_ROOT}/include"
    ENCLAVE_COMPILE_OPTIONS
      "-isystem${SGX_SDK_INCLUDE_DIRECTORY}"
      "-isystem${SGXSSL_ROOT}/include"
    TRUSTED_LIBRARIES "${SGXSSL_ROOT}/lib/libsgx_tsgxssl_crypto.a")
endfunction()
