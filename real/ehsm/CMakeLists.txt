if(NOT EHSM_SOURCE_ROOT OR NOT SGXSSL_ROOT)
  message(FATAL_ERROR "EHSM_SOURCE_ROOT and SGXSSL_ROOT must be set")
endif()

set(_EHSM_SOURCE_DIRECTORY "${EHSM_SOURCE_ROOT}/core/Enclave")
set(_EHSM_INCLUDE_DIRECTORY "${EHSM_SOURCE_ROOT}/include")
set(_EHSM_LOG_INCLUDE_DIRECTORY "${EHSM_SOURCE_ROOT}/utils/log4cplus")

sgx_add_sample(
  NAME ehsm
  EDL "${CMAKE_CURRENT_SOURCE_DIR}/enclave.edl"
  CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/Enclave.config.xml"
  PROTECT_HEAP 0x400000
  PROTECT_STACK 0x40000
  SOURCES
    "${_EHSM_SOURCE_DIRECTORY}/enclave_hsm.cpp"
    "${_EHSM_SOURCE_DIRECTORY}/key_factory.cpp"
    "${_EHSM_SOURCE_DIRECTORY}/key_operation.cpp"
    "${_EHSM_SOURCE_DIRECTORY}/openssl_operation.cpp"
  HOST_SOURCES
    "${CMAKE_CURRENT_SOURCE_DIR}/host.cpp"
    "${CMAKE_SOURCE_DIR}/common/sgxssl_cpu.c"
  INCLUDE_DIRECTORIES
    "${_EHSM_SOURCE_DIRECTORY}"
    "${_EHSM_INCLUDE_DIRECTORY}"
    "${_EHSM_LOG_INCLUDE_DIRECTORY}"
    "${SGXSSL_ROOT}/include"
  SEARCH_PATHS
    "${_EHSM_INCLUDE_DIRECTORY}"
    "${_EHSM_LOG_INCLUDE_DIRECTORY}"
    "${SGXSSL_ROOT}/include"
    "${SGXSSL_ROOT}/include/nofilefunc"
  HOST_INCLUDE_DIRECTORIES
    "${_EHSM_INCLUDE_DIRECTORY}"
    "${CMAKE_SOURCE_DIR}/common"
    "${SGXSSL_ROOT}/include"
  HOST_LIBRARIES "${SGXSSL_ROOT}/lib/libsgx_usgxssl.a"
  ENCLAVE_COMPILE_OPTIONS
    "-isystem${SGX_SDK_INCLUDE_DIRECTORY}"
    "$<$<COMPILE_LANGUAGE:CXX>:-include${SGXSSL_ROOT}/include/tsgxsslio.h>"
  TRUSTED_LIBRARIES
    "-Wl,--whole-archive"
    "${SGXSSL_ROOT}/lib/libsgx_tsgxssl.a"
    "-Wl,--no-whole-archive"
    "${SGXSSL_ROOT}/lib/libsgx_tsgxssl_crypto.a"
  PROFILE PRERELEASE)
