sgx_add_sample(
  NAME qe3
  EDL "${CMAKE_CURRENT_SOURCE_DIR}/qe3_enclave.edl"
  CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/Enclave.config.xml"
  PROTECT_HEAP 0x100000
  PROTECT_STACK 0x40000
  PROTECT_Q 0x2000
  SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/enclave.cpp"
  HOST_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/host.c"
  INCLUDE_DIRECTORIES
    "${QE3_SOURCE_ROOT}/ae/dep/inc/internal"
    "${QE3_SOURCE_ROOT}/QuoteGeneration/quote_wrapper/common/inc"
  SEARCH_PATHS
    "${QE3_SOURCE_ROOT}/ae/dep/inc/internal"
    "${QE3_SOURCE_ROOT}/QuoteGeneration/common/inc/internal"
    "${QE3_SOURCE_ROOT}/QuoteGeneration/quote_wrapper/common/inc"
  ENCLAVE_COMPILE_OPTIONS
    "-idirafter${QE3_SOURCE_ROOT}/QuoteGeneration/common/inc/internal"
  PROFILE PRERELEASE)
