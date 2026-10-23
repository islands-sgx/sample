include("${CMAKE_SOURCE_DIR}/bench/micro/common/BenchSample.cmake")

find_path(
  MLKEM_SGX_ROOT
  NAMES include/mlkem_native.h
  HINTS ENV MLKEM_SGX_ROOT
  NO_DEFAULT_PATH
  REQUIRED)

bench_add_sample(
  NAME mlkem-768
  HOST_SOURCES answer.c
  INCLUDE_DIRECTORIES "${MLKEM_SGX_ROOT}/include"
  COMPILE_DEFINITIONS MLK_CONFIG_PARAMETER_SET=768 MLK_CONFIG_NO_RANDOMIZED_API
  TRUSTED_LIBRARIES "${MLKEM_SGX_ROOT}/lib/libmlkem-native-sgx.a")
