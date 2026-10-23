include("${CMAKE_SOURCE_DIR}/bench/micro/common/BenchSample.cmake")

find_path(
  MLDSA_SGX_ROOT
  NAMES include/mldsa_native.h
  HINTS ENV MLDSA_SGX_ROOT
  NO_DEFAULT_PATH
  REQUIRED)

bench_add_sample(
  NAME mldsa-65
  HOST_SOURCES answer.c
  INCLUDE_DIRECTORIES "${MLDSA_SGX_ROOT}/include"
  COMPILE_DEFINITIONS MLD_CONFIG_PARAMETER_SET=65 MLD_CONFIG_NO_RANDOMIZED_API
  TRUSTED_LIBRARIES "${MLDSA_SGX_ROOT}/lib/libmldsa-native-sgx.a")
