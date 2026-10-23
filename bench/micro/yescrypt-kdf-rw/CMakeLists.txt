include("${CMAKE_SOURCE_DIR}/bench/micro/common/BenchSample.cmake")

find_path(
  YESCRYPT_SGX_ROOT
  NAMES include/yescrypt.h
  HINTS ENV YESCRYPT_SGX_ROOT
  NO_DEFAULT_PATH
  REQUIRED)

bench_add_sample(
  NAME yescrypt-kdf-rw
  WARMUP_ROUNDS 50
  MEASURED_ROUNDS 500
  HOST_SOURCES answer.c
  INCLUDE_DIRECTORIES "${YESCRYPT_SGX_ROOT}/include"
  TRUSTED_LIBRARIES "${YESCRYPT_SGX_ROOT}/lib/libyescrypt-sgx.a")
