include("${CMAKE_SOURCE_DIR}/bench/common/BenchSample.cmake")

find_path(
  WOLFSSL_SGX_ROOT
  NAMES include/wolfssl/wolfcrypt/pwdbased.h
  HINTS ENV WOLFSSL_SGX_ROOT
  NO_DEFAULT_PATH
  REQUIRED)

bench_add_sample(
  NAME wolfssl-pbkdf2-sha256
  PROTECT_HEAP 0x100000
  PROTECT_STACK 0x40000
  HOST_SOURCES answer.c
  INCLUDE_DIRECTORIES "${WOLFSSL_SGX_ROOT}/include"
  COMPILE_DEFINITIONS WOLFSSL_USER_SETTINGS
  TRUSTED_LIBRARIES "${WOLFSSL_SGX_ROOT}/lib/libwolfssl-sgx.a")
