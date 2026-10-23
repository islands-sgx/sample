include("${CMAKE_SOURCE_DIR}/bench/micro/common/BenchSample.cmake")

find_path(
  WOLFSSL_SGX_ROOT
  NAMES include/wolfssl/wolfcrypt/pwdbased.h
  HINTS ENV WOLFSSL_SGX_ROOT
  NO_DEFAULT_PATH
  REQUIRED)

bench_add_sample(
  NAME wolfssl-pbkdf2-sha256
  WARMUP_ROUNDS 50
  MEASURED_ROUNDS 500
  HOST_SOURCES answer.c
  INCLUDE_DIRECTORIES "${WOLFSSL_SGX_ROOT}/include"
  COMPILE_DEFINITIONS WOLFSSL_USER_SETTINGS
  TRUSTED_LIBRARIES "${WOLFSSL_SGX_ROOT}/lib/libwolfssl-sgx.a")
