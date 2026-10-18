# Intel SGX hardware sample helpers for x86-64.

include_guard(GLOBAL)
include(CMakeParseArguments)

function(_sgx_profile profile output_optimization output_app_definitions)
  if(NOT profile)
    set(profile DEBUG)
  endif()
  string(TOUPPER "${profile}" profile)
  if(profile STREQUAL DEBUG)
    set(optimization -O0 -g)
    set(app_definitions -DDEBUG -UNDEBUG -UEDEBUG)
  elseif(profile STREQUAL PRERELEASE)
    set(optimization -O2)
    set(app_definitions -DNDEBUG -DEDEBUG -UDEBUG)
  else()
    message(FATAL_ERROR "[SGX] PROFILE must be DEBUG or PRERELEASE (got '${profile}')")
  endif()
  set(${output_optimization} ${optimization} PARENT_SCOPE)
  set(${output_app_definitions} ${app_definitions} PARENT_SCOPE)
endfunction()

function(_sgx_optimization profile optimization output_flags)
  _sgx_profile("${profile}" profile_flags unused_definitions)
  if(NOT optimization)
    set(flags ${profile_flags})
  else()
    string(TOUPPER "${optimization}" optimization)
    if(NOT optimization STREQUAL O3)
      message(FATAL_ERROR "[SGX] OPTIMIZATION must be O3 when specified")
    endif()
    set(flags -O3)
  endif()
  set(${output_flags} ${flags} PARENT_SCOPE)
endfunction()

function(sgx_find_sdk)
  if(NOT CMAKE_C_COMPILER_ID STREQUAL Clang)
    message(FATAL_ERROR "[SGX] this build requires Clang; got ${CMAKE_C_COMPILER_ID} ${CMAKE_C_COMPILER_VERSION}")
  endif()
  if(NOT CMAKE_CXX_COMPILER_ID STREQUAL Clang)
    message(FATAL_ERROR "[SGX] this build requires Clang++; got ${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
  endif()
  if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "[SGX] only the official x86-64 build is supported")
  endif()

  execute_process(
    COMMAND "${CMAKE_C_COMPILER}" -print-resource-dir
    RESULT_VARIABLE resource_result
    OUTPUT_VARIABLE resource_directory
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
  if(NOT resource_result EQUAL 0
     OR NOT IS_DIRECTORY "${resource_directory}/include")
    message(FATAL_ERROR "[SGX] unable to locate Clang builtin headers")
  endif()
  set(SGX_CLANG_RESOURCE_INCLUDE_DIRECTORY
      "${resource_directory}/include" PARENT_SCOPE)

  if(NOT DEFINED ATFIELD_LLC OR NOT IS_EXECUTABLE "${ATFIELD_LLC}")
    message(FATAL_ERROR "[SGX] ATFIELD_LLC must name the pinned llc executable")
  endif()
  if(NOT CMAKE_OBJCOPY OR NOT IS_EXECUTABLE "${CMAKE_OBJCOPY}")
    message(FATAL_ERROR "[SGX] CMAKE_OBJCOPY must name the pinned llvm-objcopy")
  endif()
  if(NOT DEFINED SGX_ENCLAVE_CLANG
     OR NOT IS_EXECUTABLE "${SGX_ENCLAVE_CLANG}")
    message(FATAL_ERROR "[SGX] SGX_ENCLAVE_CLANG must name the enclave compiler wrapper")
  endif()

  if(NOT DEFINED SGX_SDK_ROOT OR SGX_SDK_ROOT STREQUAL "")
    if(DEFINED ENV{SGX_SDK_ROOT} AND NOT "$ENV{SGX_SDK_ROOT}" STREQUAL "")
      set(SGX_SDK_ROOT "$ENV{SGX_SDK_ROOT}")
    else()
      message(FATAL_ERROR "[SGX] set SGX_SDK_ROOT to the Intel SGX SDK root")
    endif()
  endif()
  get_filename_component(sdk_root "${SGX_SDK_ROOT}" REALPATH)
  if(NOT IS_DIRECTORY "${sdk_root}")
    message(FATAL_ERROR "[SGX] SGX_SDK_ROOT is not a directory: ${sdk_root}")
  endif()
  set(SGX_SDK_ROOT "${sdk_root}" PARENT_SCOPE)
  set(SGX_SDK_BINARY_DIRECTORY "${sdk_root}/bin/x64" PARENT_SCOPE)
  set(SGX_SDK_EDGER8R "${sdk_root}/bin/x64/sgx_edger8r" PARENT_SCOPE)
  set(SGX_SDK_SIGN "${sdk_root}/bin/x64/sgx_sign" PARENT_SCOPE)
  set(SGX_SDK_INCLUDE_DIRECTORY "${sdk_root}/include" PARENT_SCOPE)
  if(NOT IS_EXECUTABLE "${sdk_root}/bin/x64/sgx_edger8r"
     OR NOT IS_EXECUTABLE "${sdk_root}/bin/x64/sgx_sign")
    message(FATAL_ERROR "[SGX] sgx_edger8r/sgx_sign missing under ${sdk_root}/bin/x64")
  endif()
  if(NOT IS_DIRECTORY "${sdk_root}/include")
    message(FATAL_ERROR "[SGX] SDK include directory missing: ${sdk_root}/include")
  endif()

  set(trusted_root "${sdk_root}")
  if(DEFINED SGX_TRUSTED_LIB_ROOT AND NOT SGX_TRUSTED_LIB_ROOT STREQUAL "")
    get_filename_component(trusted_root "${SGX_TRUSTED_LIB_ROOT}" REALPATH)
  elseif(DEFINED ENV{SGX_TRUSTED_LIB_ROOT} AND NOT "$ENV{SGX_TRUSTED_LIB_ROOT}" STREQUAL "")
    get_filename_component(trusted_root "$ENV{SGX_TRUSTED_LIB_ROOT}" REALPATH)
  endif()
  if(IS_DIRECTORY "${trusted_root}/lib")
    set(trusted_library_directory "${trusted_root}/lib")
  elseif(IS_DIRECTORY "${trusted_root}/lib64")
    set(trusted_library_directory "${trusted_root}/lib64")
  else()
    message(FATAL_ERROR "[SGX] SDK trusted library directory missing under ${trusted_root}")
  endif()
  set(SGX_TRUSTED_LIBRARY_DIRECTORY
      "${trusted_library_directory}" PARENT_SCOPE)

  if(NOT DEFINED SGX_PSW_ROOT OR SGX_PSW_ROOT STREQUAL "")
    if(DEFINED ENV{SGX_PSW_ROOT} AND NOT "$ENV{SGX_PSW_ROOT}" STREQUAL "")
      set(SGX_PSW_ROOT "$ENV{SGX_PSW_ROOT}")
    else()
      message(FATAL_ERROR "[SGX] set SGX_PSW_ROOT to the Intel SGX PSW root")
    endif()
  endif()
  get_filename_component(psw_root "${SGX_PSW_ROOT}" REALPATH)
  if(IS_DIRECTORY "${psw_root}/lib64")
    set(psw_library_directory "${psw_root}/lib64")
  elseif(IS_DIRECTORY "${psw_root}/lib")
    set(psw_library_directory "${psw_root}/lib")
  else()
    message(FATAL_ERROR "[SGX] PSW library directory missing under ${psw_root}")
  endif()
  set(SGX_PSW_ROOT "${psw_root}" PARENT_SCOPE)
  set(SGX_PSW_LIBRARY_DIRECTORY "${psw_library_directory}" PARENT_SCOPE)
  set(psw_runtime_directories)
  foreach(runtime_directory IN ITEMS "${psw_root}/lib64" "${psw_root}/lib")
    if(IS_DIRECTORY "${runtime_directory}")
      list(APPEND psw_runtime_directories "${runtime_directory}")
    endif()
  endforeach()
  set(SGX_PSW_RUNTIME_DIRECTORIES
      "${psw_runtime_directories}" PARENT_SCOPE)

  message(STATUS "[SGX] SDK root: ${sdk_root}")
  message(STATUS "[SGX] PSW runtime: ${psw_library_directory}")
endfunction()

function(sgx_add_sample)
  set(one_value_args NAME EDL CONFIG PROFILE OPTIMIZATION)
  set(multi_value_args SOURCES HOST_SOURCES INCLUDE_DIRECTORIES SEARCH_PATHS
      TRUSTED_LIBRARIES HOST_INCLUDE_DIRECTORIES HOST_LIBRARIES
      ENCLAVE_COMPILE_OPTIONS)
  cmake_parse_arguments(ARG "" "${one_value_args}" "${multi_value_args}"
                        ${ARGN})
  if(ARG_UNPARSED_ARGUMENTS OR ARG_KEYWORDS_MISSING_VALUES)
    message(FATAL_ERROR "[SGX] sgx_add_sample received unknown or incomplete arguments")
  endif()
  if(NOT ARG_NAME OR NOT ARG_EDL OR NOT ARG_SOURCES OR NOT ARG_HOST_SOURCES)
    message(FATAL_ERROR "[SGX] sgx_add_sample requires NAME, EDL, SOURCES, and HOST_SOURCES")
  endif()
  if(NOT ARG_CONFIG)
    set(ARG_CONFIG Enclave.config.xml)
  endif()
  if(NOT ARG_PROFILE)
    set(ARG_PROFILE DEBUG)
  endif()
  string(TOUPPER "${ARG_PROFILE}" ARG_PROFILE)
  _sgx_profile("${ARG_PROFILE}" unused_flags host_definitions)
  _sgx_optimization("${ARG_PROFILE}" "${ARG_OPTIMIZATION}" optimization_flags)

  string(REPLACE "-" "_" target_name "${ARG_NAME}")
  set(enclave_target "${target_name}_enclave")
  set(edl_target "${enclave_target}_edl")

  foreach(path_kind EDL CONFIG)
    set(path_in "${ARG_${path_kind}}")
    if(IS_ABSOLUTE "${path_in}")
      set(${path_kind}_PATH "${path_in}")
    else()
      set(${path_kind}_PATH "${CMAKE_CURRENT_SOURCE_DIR}/${path_in}")
    endif()
    get_filename_component(${path_kind}_PATH "${${path_kind}_PATH}" REALPATH)
    if(NOT EXISTS "${${path_kind}_PATH}")
      message(FATAL_ERROR "[SGX] ${path_kind} not found: ${${path_kind}_PATH}")
    endif()
  endforeach()

  get_filename_component(edl_directory "${EDL_PATH}" DIRECTORY)
  get_filename_component(edl_name "${EDL_PATH}" NAME_WE)
  set(search_paths "${edl_directory}" "${CMAKE_CURRENT_SOURCE_DIR}"
      "${SGX_SDK_INCLUDE_DIRECTORY}" ${ARG_SEARCH_PATHS})
  list(REMOVE_DUPLICATES search_paths)
  set(search_args)
  foreach(search_path IN LISTS search_paths)
    list(APPEND search_args --search-path "${search_path}")
  endforeach()

  set(trusted_directory "${CMAKE_CURRENT_BINARY_DIR}/${edl_target}_trusted")
  set(untrusted_directory "${CMAKE_CURRENT_BINARY_DIR}/${edl_target}_untrusted")
  file(MAKE_DIRECTORY "${trusted_directory}" "${untrusted_directory}")
  set(trusted_bridge "${trusted_directory}/${edl_name}_t.c")
  set(untrusted_bridge "${untrusted_directory}/${edl_name}_u.c")
  add_custom_command(
    OUTPUT "${untrusted_directory}/${edl_name}_u.h" "${untrusted_bridge}"
    COMMAND "${SGX_SDK_EDGER8R}" --untrusted "${EDL_PATH}" ${search_args}
    WORKING_DIRECTORY "${untrusted_directory}"
    DEPENDS "${SGX_SDK_EDGER8R}" "${EDL_PATH}"
    COMMENT "[SGX] edger8r untrusted bridge for ${edl_name}"
    VERBATIM)
  add_custom_command(
    OUTPUT "${trusted_directory}/${edl_name}_t.h" "${trusted_bridge}"
    COMMAND "${SGX_SDK_EDGER8R}" --trusted "${EDL_PATH}" ${search_args}
    WORKING_DIRECTORY "${trusted_directory}"
    DEPENDS "${SGX_SDK_EDGER8R}" "${EDL_PATH}"
    COMMENT "[SGX] edger8r trusted bridge for ${edl_name}"
    VERBATIM)

  if(ATFIELD_MODE STREQUAL anchor)
    set(anchor_preparation 1)
  else()
    set(anchor_preparation 0)
  endif()
  set(codegen_launcher
      "${CMAKE_COMMAND}" -E env
      "ATFIELD_ANCHOR_PREPARATION=${anchor_preparation}"
      "ATFIELD_PAYLOAD_NAMESPACE=${ATFIELD_GROUP}/${ATFIELD_SAMPLE}"
      "ATFIELD_SOURCE_ROOT=${CMAKE_CURRENT_SOURCE_DIR}"
      "ATFIELD_LLC=${ATFIELD_LLC}"
      "ATFIELD_UPSTREAM_SOURCE_ROOT=${ATFIELD_UPSTREAM_SOURCE_ROOT}"
      "ATFIELD_UPSTREAM_PACKAGE=${ATFIELD_UPSTREAM_PACKAGE}"
      "${SGX_ENCLAVE_CLANG}" --cmake-launcher)

  foreach(library_name trts tstdc tcxx tcrypto tservice)
    find_library(sgx_library_${library_name}
      NAMES sgx_${library_name}
      PATHS "${SGX_TRUSTED_LIBRARY_DIRECTORY}"
      NO_DEFAULT_PATH NO_CACHE REQUIRED)
  endforeach()

  add_executable(${enclave_target} "${trusted_bridge}" ${ARG_SOURCES})
  set_target_properties(${enclave_target} PROPERTIES
    PREFIX ""
    OUTPUT_NAME enclave
    SUFFIX .so
    LINK_DEPENDS "${CMAKE_SOURCE_DIR}/cmake/Enclave.lds"
    C_COMPILER_LAUNCHER "${codegen_launcher}"
    CXX_COMPILER_LAUNCHER "${codegen_launcher}")
  target_include_directories(${enclave_target} PRIVATE
    "${SGX_SDK_INCLUDE_DIRECTORY}"
    "${SGX_SDK_INCLUDE_DIRECTORY}/tlibc"
    "$<$<COMPILE_LANGUAGE:CXX>:${SGX_SDK_INCLUDE_DIRECTORY}/libcxx>"
    "$<$<COMPILE_LANGUAGE:CXX>:${SGX_SDK_INCLUDE_DIRECTORY}/stdc++>"
    "$<$<COMPILE_LANGUAGE:CXX>:${SGX_SDK_INCLUDE_DIRECTORY}/stdc++/linux>"
    ${ARG_INCLUDE_DIRECTORIES}
    "${trusted_directory}"
    "${CMAKE_SOURCE_DIR}/common"
    "${CMAKE_CURRENT_SOURCE_DIR}")
  target_compile_options(${enclave_target} PRIVATE
    -m64 -mno-red-zone ${optimization_flags}
    -nostdinc -ffreestanding -fvisibility=hidden -fpie
    -fno-strict-aliasing -fwrapv -fno-delete-null-pointer-checks
    -fstack-protector-strong -ffunction-sections -fdata-sections
    "$<$<COMPILE_LANGUAGE:C>:-Wstrict-prototypes>"
    "$<$<COMPILE_LANGUAGE:CXX>:-nostdinc++>"
    "$<$<COMPILE_LANGUAGE:CXX>:-include${SGX_SDK_INCLUDE_DIRECTORY}/libcxx/__sgx>"
    "$<$<COMPILE_LANGUAGE:CXX>:-D_LIBCPP_HAS_NO_VENDOR_AVAILABILITY_ANNOTATIONS>"
    "-include${CMAKE_SOURCE_DIR}/common/atfield.h"
    "-I${SGX_CLANG_RESOURCE_INCLUDE_DIRECTORY}"
    ${ARG_ENCLAVE_COMPILE_OPTIONS})
  target_link_options(${enclave_target} PRIVATE
    -Wl,-z,relro,-z,now,-z,noexecstack
    -Wl,--fatal-warnings -Wl,--as-needed -Wl,--no-undefined
    -Wl,--no-undefined-version -nostdlib -nodefaultlibs -nostartfiles
    -Wl,-Bstatic -Wl,-Bsymbolic -Wl,-pie,-eenclave_entry
    -Wl,--export-dynamic -Wl,--defsym,__ImageBase=0 -Wl,--gc-sections
    "-Wl,--version-script=${CMAKE_SOURCE_DIR}/cmake/Enclave.lds")
  target_link_libraries(${enclave_target} PRIVATE
    "-Wl,--whole-archive" "${sgx_library_trts}" "-Wl,--no-whole-archive"
    "-Wl,--start-group" ${ARG_TRUSTED_LIBRARIES}
    "${sgx_library_tstdc}" "${sgx_library_tcxx}"
    "${sgx_library_tcrypto}" "${sgx_library_tservice}" "-Wl,--end-group")

  set(key_path "${ATFIELD_TEST_SIGNING_KEY}")
  get_filename_component(key_directory "${key_path}" DIRECTORY)
  find_program(sgx_openssl NAMES openssl REQUIRED)
  add_custom_command(
    OUTPUT "${key_path}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${key_directory}"
    COMMAND "${CMAKE_COMMAND}"
            "-DKEY_PATH=${key_path}"
            "-DOPENSSL_EXECUTABLE=${sgx_openssl}"
            -P "${CMAKE_SOURCE_DIR}/scripts/ensure-signing-key.cmake"
    DEPENDS "${CMAKE_SOURCE_DIR}/scripts/ensure-signing-key.cmake"
    COMMENT "[SGX] ensuring test signing key ${key_path}"
    VERBATIM)
  set(signed_file "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/enclave.signed.so")
  add_custom_command(
    OUTPUT "${signed_file}"
    COMMAND "${SGX_SDK_SIGN}" sign -key "${key_path}"
            -enclave "$<TARGET_FILE:${enclave_target}>"
            -out "${signed_file}" -config "${CONFIG_PATH}"
    # The analysis ELF keeps all symbols; the signed publication keeps SGX metadata.
    COMMAND "${CMAKE_OBJCOPY}" --strip-all --keep-section=.note.sgxmeta
            "${signed_file}"
    DEPENDS ${enclave_target} "${key_path}" "${CONFIG_PATH}"
    COMMENT "[SGX] signing enclave ${signed_file}"
    VERBATIM)
  add_custom_target(${enclave_target}_signed ALL DEPENDS "${signed_file}")

  find_library(sgx_urts_library
    NAMES sgx_urts
    PATHS "${SGX_PSW_LIBRARY_DIRECTORY}"
    NO_DEFAULT_PATH NO_CACHE REQUIRED)
  add_executable(host ${ARG_HOST_SOURCES} "${untrusted_bridge}")
  target_include_directories(host PRIVATE
    "${SGX_SDK_INCLUDE_DIRECTORY}"
    "${untrusted_directory}"
    "${CMAKE_CURRENT_SOURCE_DIR}"
    ${ARG_HOST_INCLUDE_DIRECTORIES})
  target_compile_options(host PRIVATE
    -m64 ${optimization_flags} -fPIC
    "$<$<COMPILE_LANGUAGE:C>:-Wstrict-prototypes>"
    ${host_definitions})
  target_compile_definitions(host PRIVATE
    "ENCLAVE_PATH=\"${signed_file}\"")
  target_link_libraries(host PRIVATE
    ${ARG_HOST_LIBRARIES} "${sgx_urts_library}" pthread)
  set_target_properties(host PROPERTIES
    BUILD_RPATH "${SGX_PSW_RUNTIME_DIRECTORIES}"
    INSTALL_RPATH "${SGX_PSW_RUNTIME_DIRECTORIES}")
  add_dependencies(host ${enclave_target}_signed)
endfunction()
