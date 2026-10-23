include_guard(GLOBAL)
include(CMakeParseArguments)

function(bench_add_sample)
  set(options)
  set(oneValueArgs NAME PROFILE OPTIMIZATION PROTECT_Q WARMUP_ROUNDS MEASURED_ROUNDS)
  set(multiValueArgs INCLUDE_DIRECTORIES COMPILE_DEFINITIONS TRUSTED_LIBRARIES HOST_LIBRARIES
                     HOST_SOURCES ENCLAVE_COMPILE_OPTIONS)
  cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  if(NOT ARG_NAME OR NOT ARG_TRUSTED_LIBRARIES)
    message(FATAL_ERROR "bench_add_sample requires NAME and TRUSTED_LIBRARIES")
  endif()
  if(NOT ARG_PROFILE)
    set(ARG_PROFILE DEBUG)
  endif()

  set(_BENCH_COMMON_DIRECTORY "${CMAKE_SOURCE_DIR}/bench/micro/common")
  foreach(_BENCH_FILE IN ITEMS sample.c Enclave.config.xml)
    if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_BENCH_FILE}")
      message(FATAL_ERROR "${ARG_NAME}: missing ${CMAKE_CURRENT_SOURCE_DIR}/${_BENCH_FILE}")
    endif()
  endforeach()

  set(_compile_opts ${ARG_ENCLAVE_COMPILE_OPTIONS})
  foreach(_def IN LISTS ARG_COMPILE_DEFINITIONS)
    list(APPEND _compile_opts "-D${_def}")
  endforeach()

  set(_extra_args)
  if(ARG_OPTIMIZATION)
    list(APPEND _extra_args OPTIMIZATION "${ARG_OPTIMIZATION}")
  endif()
  if(ARG_PROTECT_Q)
    list(APPEND _extra_args PROTECT_Q "${ARG_PROTECT_Q}")
  endif()
  if(_compile_opts)
    list(APPEND _extra_args ENCLAVE_COMPILE_OPTIONS ${_compile_opts})
  endif()
  if(ARG_HOST_LIBRARIES)
    list(APPEND _extra_args HOST_LIBRARIES ${ARG_HOST_LIBRARIES})
  endif()

  sgx_add_sample(
    NAME "${ARG_NAME}"
    EDL "${_BENCH_COMMON_DIRECTORY}/bench.edl"
    CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/Enclave.config.xml"
    PROFILE "${ARG_PROFILE}"
    SOURCES "${_BENCH_COMMON_DIRECTORY}/enclave.c" "${CMAKE_CURRENT_SOURCE_DIR}/sample.c"
    HOST_SOURCES "${_BENCH_COMMON_DIRECTORY}/host.c" ${ARG_HOST_SOURCES}
    SEARCH_PATHS "${_BENCH_COMMON_DIRECTORY}" ${ARG_INCLUDE_DIRECTORIES}
    INCLUDE_DIRECTORIES "${_BENCH_COMMON_DIRECTORY}" ${ARG_INCLUDE_DIRECTORIES}
    HOST_INCLUDE_DIRECTORIES "${_BENCH_COMMON_DIRECTORY}"
    TRUSTED_LIBRARIES ${ARG_TRUSTED_LIBRARIES}
    ${_extra_args})

  set(_host_definitions "SAMPLE_NAME=\"${ARG_NAME}\"")
  if(ARG_WARMUP_ROUNDS)
    list(APPEND _host_definitions "DEFAULT_WARMUP_ROUNDS=${ARG_WARMUP_ROUNDS}")
  endif()
  if(ARG_MEASURED_ROUNDS)
    list(APPEND _host_definitions "DEFAULT_MEASURED_ROUNDS=${ARG_MEASURED_ROUNDS}")
  endif()
  target_compile_definitions(host PRIVATE ${_host_definitions})
  if(TARGET host_measurement)
    target_compile_definitions(host_measurement PRIVATE ${_host_definitions})
  endif()
endfunction()
