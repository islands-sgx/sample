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

# Nix's cc wrapper adds NIX_LDFLAGS to the final link command. Dev-shell flags
# may contain an output-directory RPATH under the current checkout, which makes
# enclave measurements checkout-dependent. Clear linker RPATH options only for
# enclave links; host links use the same filtered environment while retaining
# their explicit PSW runtime paths below.
function(_sgx_enclave_nix_ldflags output_flags)
  separate_arguments(raw_flags UNIX_COMMAND "$ENV{NIX_LDFLAGS}")
  set(clean_flags)
  set(skip_value FALSE)
  foreach(flag IN LISTS raw_flags)
    if(skip_value)
      if(flag MATCHES "^-")
        message(FATAL_ERROR "[SGX] missing RPATH value before '${flag}' in NIX_LDFLAGS")
      endif()
      set(skip_value FALSE)
    elseif(flag STREQUAL "-rpath" OR flag STREQUAL "--rpath" OR flag STREQUAL "-R")
      set(skip_value TRUE)
    elseif(flag MATCHES "^(-rpath|--rpath|--?R)=")
      # Drop joined forms such as -rpath=/some/path.
    elseif(flag MATCHES "^-Wl,.*(^|,)(-rpath|--rpath|-R)(,|=)")
      message(FATAL_ERROR "[SGX] unsupported -Wl RPATH form in NIX_LDFLAGS: ${flag}")
    else()
      list(APPEND clean_flags "${flag}")
    endif()
  endforeach()
  if(skip_value)
    message(FATAL_ERROR "[SGX] incomplete RPATH option in NIX_LDFLAGS")
  endif()
  list(JOIN clean_flags " " clean_value)
  set(${output_flags} "${clean_value}" PARENT_SCOPE)
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
  set(one_value_args NAME EDL CONFIG PROFILE OPTIMIZATION
      PROTECT_HEAP PROTECT_STACK PROTECT_Q)
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

  if(ATFIELD_MODE STREQUAL protect)
    if(NOT ATFIELD_IMPLEMENT_ROOT OR
       NOT EXISTS "${ATFIELD_IMPLEMENT_ROOT}/cli/protect-config.ts")
      message(FATAL_ERROR "protect requires the implement repository tools")
    endif()
    if(NOT ARG_PROTECT_HEAP OR NOT ARG_PROTECT_STACK OR NOT ARG_PROTECT_Q)
      message(FATAL_ERROR "protect requires PROTECT_HEAP, PROTECT_STACK, and PROTECT_Q")
    endif()
    if(NOT ATFIELD_FIELD_TOOL OR NOT IS_EXECUTABLE "${ATFIELD_FIELD_TOOL}")
      message(FATAL_ERROR "protect requires a built ATFIELD_FIELD_TOOL")
    endif()
    math(EXPR protect_q "${ARG_PROTECT_Q}")
    math(EXPR protect_q_remainder "${protect_q} % 4096")
    if(protect_q LESS_EQUAL 0 OR NOT protect_q_remainder EQUAL 0)
      message(FATAL_ERROR "protect Q must be positive and page aligned")
    endif()
    set(selector_path "${CMAKE_CURRENT_SOURCE_DIR}/selectors.json")
    if(NOT EXISTS "${selector_path}")
      message(FATAL_ERROR "protect requires ${selector_path}")
    endif()
    set(original_config "${CONFIG_PATH}")
    set(CONFIG_PATH "${CMAKE_BINARY_DIR}/Enclave.protect.config.xml")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
      "${original_config}" "${ATFIELD_IMPLEMENT_ROOT}/cli/protect-config.ts")
    execute_process(
      COMMAND "${ATFIELD_IMPLEMENT_ROOT}/cli/protect-config.ts"
        "${original_config}" "${CONFIG_PATH}"
        --heap "${ARG_PROTECT_HEAP}" --stack "${ARG_PROTECT_STACK}"
      RESULT_VARIABLE config_result)
    if(NOT config_result EQUAL 0)
      message(FATAL_ERROR "failed to derive protect signing config")
    endif()
  endif()

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

  if(ATFIELD_MODE STREQUAL raw)
    set(anchor_preparation 0)
    set(field_boundary 0)
  elseif(ATFIELD_MODE STREQUAL anchor)
    set(anchor_preparation 1)
    set(field_boundary 0)
  else()
    set(anchor_preparation 1)
    set(field_boundary 1)
  endif()
  set(codegen_launcher
      "${CMAKE_COMMAND}" -E env
      "ATFIELD_ANCHOR_PREPARATION=${anchor_preparation}"
      "ATFIELD_FIELD_BOUNDARY=${field_boundary}"
      "ATFIELD_IMPLEMENT_ROOT=${ATFIELD_IMPLEMENT_ROOT}"
      "ATFIELD_PAYLOAD_NAMESPACE=${ATFIELD_GROUP}/${ATFIELD_SAMPLE}"
      "ATFIELD_SOURCE_ROOT=${CMAKE_CURRENT_SOURCE_DIR}"
      "ATFIELD_LLC=${ATFIELD_LLC}"
      "ATFIELD_UPSTREAM_SOURCE_ROOT=${ATFIELD_UPSTREAM_SOURCE_ROOT}"
      "ATFIELD_UPSTREAM_PACKAGE=${ATFIELD_UPSTREAM_PACKAGE}"
      "ATFIELD_FIELD_TOOL=${ATFIELD_FIELD_TOOL}"
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
  _sgx_enclave_nix_ldflags(enclave_nix_ldflags)
  if(NOT ATFIELD_MODE STREQUAL protect)
    set(enclave_link_launcher
      "${CMAKE_COMMAND}" -E env "NIX_LDFLAGS=${enclave_nix_ldflags}")
    set_target_properties(${enclave_target} PROPERTIES
      C_LINKER_LAUNCHER "${enclave_link_launcher}"
      CXX_LINKER_LAUNCHER "${enclave_link_launcher}")
  endif()
  if(ATFIELD_MODE STREQUAL protect)
    set_target_properties(${enclave_target} PROPERTIES OUTPUT_NAME enclave.profile)
    set(profile_link_launcher
      "${CMAKE_COMMAND}" -E env "NIX_LDFLAGS=${enclave_nix_ldflags}"
      "${ATFIELD_IMPLEMENT_ROOT}/cli/profile-link.ts"
      --field-tool "${ATFIELD_FIELD_TOOL}"
      --pretouch-tool "${ATFIELD_IMPLEMENT_ROOT}/build/pretouch/pretouch.ts"
      --capacity-q "${protect_q}"
      --assembler "${CMAKE_C_COMPILER}"
      --linker-script "${ATFIELD_IMPLEMENT_ROOT}/build/pretouch/post-rx-segment.ld"
      --)
    set_target_properties(${enclave_target} PROPERTIES
      C_LINKER_LAUNCHER "${profile_link_launcher}"
      CXX_LINKER_LAUNCHER "${profile_link_launcher}")
    set_property(TARGET ${enclave_target} APPEND PROPERTY LINK_DEPENDS
      "${ATFIELD_FIELD_TOOL}"
      "${ATFIELD_IMPLEMENT_ROOT}/cli/profile-link.ts"
      "${ATFIELD_IMPLEMENT_ROOT}/build/pretouch/pretouch.ts"
      "${ATFIELD_IMPLEMENT_ROOT}/build/workset/workset.ts"
      "${ATFIELD_IMPLEMENT_ROOT}/build/pretouch/post-rx-segment.ld")
    # The link launcher writes this manifest before the target's post-build step.
    # Declare the side effect so Ninja can order the signed-layout pipeline.
    add_custom_command(TARGET ${enclave_target} POST_BUILD
      BYPRODUCTS "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/fields.json"
      COMMAND "${CMAKE_COMMAND}" -E true)
  endif()
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
  if(ATFIELD_MODE STREQUAL protect)
    set(protect_directory "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}")
    set(fields_file "${protect_directory}/fields.json")
    set(profile_signed "${protect_directory}/enclave.profile.signed.so")
    set(workset_file "${protect_directory}/workset.json")
    set(final_file "${protect_directory}/enclave.so")
    set(final_signed_unstripped "${protect_directory}/enclave.final.signed.unstripped.so")
    set(finalized_file "${protect_directory}/pretouch-finalized.json")
    set(verified_file "${protect_directory}/pretouch-verified.json")
    set(ready_file "${protect_directory}/ready.bin")
    set(ready_summary "${protect_directory}/ready.json")
    set(target_manifest_file "${protect_directory}/target_manifest.json")
    set(scenarios_file "${CMAKE_CURRENT_SOURCE_DIR}/scenarios.json")
    file(WRITE "${target_manifest_file}" "{\n"
      "  \"schema\": \"atfield-target-manifest-v1\",\n"
      "  \"group\": \"${ATFIELD_GROUP}\",\n"
      "  \"name\": \"${ARG_NAME}\",\n"
      "  \"source_dir\": \"${CMAKE_CURRENT_SOURCE_DIR}\",\n"
      "  \"edl_path\": \"${EDL_PATH}\",\n"
      "  \"untrusted_bridge_c\": \"${untrusted_bridge}\",\n"
      "  \"untrusted_bridge_dir\": \"${untrusted_directory}\",\n"
      "  \"trusted_bridge_dir\": \"${trusted_directory}\",\n"
      "  \"protect_heap\": \"${ARG_PROTECT_HEAP}\",\n"
      "  \"protect_stack\": \"${ARG_PROTECT_STACK}\",\n"
      "  \"protect_q\": ${protect_q},\n"
      "  \"protect_config_xml\": \"${CONFIG_PATH}\",\n"
      "  \"original_config_xml\": \"${original_config}\",\n"
      "  \"signing_key_path\": \"${key_path}\",\n"
      "  \"selectors_json\": \"${selector_path}\",\n"
      "  \"scenarios_json\": \"${scenarios_file}\",\n"
      "  \"fields_json\": \"${fields_file}\",\n"
      "  \"compile_commands_json\": \"${CMAKE_BINARY_DIR}/compile_commands.json\",\n"
      "  \"c_compiler\": \"${CMAKE_C_COMPILER}\",\n"
      "  \"cxx_compiler\": \"${CMAKE_CXX_COMPILER}\",\n"
      "  \"objcopy\": \"${CMAKE_OBJCOPY}\",\n"
      "  \"sgx_sign\": \"${SGX_SDK_SIGN}\",\n"
      "  \"sgx_edger8r\": \"${SGX_SDK_EDGER8R}\",\n"
      "  \"sgx_sdk_include\": \"${SGX_SDK_INCLUDE_DIRECTORY}\",\n"
      "  \"psw_library_dir\": \"${SGX_PSW_LIBRARY_DIRECTORY}\",\n"
      "  \"implement_root\": \"${ATFIELD_IMPLEMENT_ROOT}\",\n"
      "  \"raw_signed_elf\": \"${CMAKE_SOURCE_DIR}/build/${ATFIELD_GROUP}/${ARG_NAME}/raw/enclave.signed.so\",\n"
      "  \"anchor_host_binary\": \"${CMAKE_SOURCE_DIR}/build/${ATFIELD_GROUP}/${ARG_NAME}/anchor/host\",\n"
      "  \"protect_host_binary\": \"${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/host\",\n"
      "  \"profile_elf\": \"${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/enclave.profile.so\",\n"
      "  \"profile_signed_elf\": \"${profile_signed}\",\n"
      "  \"all_reg_workset_json\": \"${workset_file}\",\n"
      "  \"all_reg_final_elf\": \"${final_file}\",\n"
      "  \"all_reg_signed_elf\": \"${signed_file}\",\n"
      "  \"all_reg_unstripped_signed_elf\": \"${final_signed_unstripped}\",\n"
      "  \"all_reg_pretouch_finalized_json\": \"${finalized_file}\",\n"
      "  \"all_reg_pretouch_verified_json\": \"${verified_file}\",\n"
      "  \"all_reg_ready_bin\": \"${ready_file}\",\n"
      "  \"all_reg_ready_json\": \"${ready_summary}\"\n"
      "}\n")
    add_custom_command(
      OUTPUT "${profile_signed}"
      COMMAND "${SGX_SDK_SIGN}" sign -key "${key_path}"
              -enclave "$<TARGET_FILE:${enclave_target}>"
              -out "${profile_signed}" -config "${CONFIG_PATH}"
      DEPENDS ${enclave_target} "${key_path}" "${CONFIG_PATH}"
      COMMENT "[SGX] sign Profile with the final enclave layout"
      VERBATIM)
    add_custom_command(
      OUTPUT "${workset_file}"
      COMMAND "${ATFIELD_IMPLEMENT_ROOT}/build/workset/workset.ts"
              --profile-elf "$<TARGET_FILE:${enclave_target}>"
              --signed-elf "${profile_signed}"
              --fields "${fields_file}" --capacity-q "${protect_q}"
              --selectors "${selector_path}" --edl "${EDL_PATH}"
              --out "${workset_file}"
      DEPENDS "${profile_signed}" "${fields_file}" "${selector_path}" "${EDL_PATH}"
              "${ATFIELD_IMPLEMENT_ROOT}/build/workset/workset.ts"
      COMMENT "[SGX] derive committed REG pages from signed Profile"
      VERBATIM)
    add_custom_command(
      OUTPUT "${final_file}" "${finalized_file}"
      COMMAND "${ATFIELD_IMPLEMENT_ROOT}/build/pretouch/pretouch.ts" finalize
              --profile-elf "$<TARGET_FILE:${enclave_target}>"
              --signed-profile-elf "${profile_signed}"
              --workset "${workset_file}" --fields "${fields_file}"
              --capacity-q "${protect_q}"
              --out-elf "${final_file}" --out-json "${finalized_file}"
      DEPENDS "${workset_file}"
              "${ATFIELD_IMPLEMENT_ROOT}/build/pretouch/pretouch.ts"
              "${ATFIELD_IMPLEMENT_ROOT}/build/workset/workset.ts"
      COMMENT "[SGX] fill the fixed Profile RX reservation"
      VERBATIM)
    add_custom_command(
      OUTPUT "${final_signed_unstripped}"
      COMMAND "${SGX_SDK_SIGN}" sign -key "${key_path}"
              -enclave "${final_file}"
              -out "${final_signed_unstripped}" -config "${CONFIG_PATH}"
      DEPENDS "${final_file}" "${key_path}" "${CONFIG_PATH}"
      COMMENT "[SGX] sign Final enclave"
      VERBATIM)
    add_custom_command(
      OUTPUT "${signed_file}"
      COMMAND "${CMAKE_OBJCOPY}" --strip-all --keep-section=.note.sgxmeta
              "${final_signed_unstripped}" "${signed_file}"
      DEPENDS "${final_signed_unstripped}"
      COMMENT "[SGX] publish stripped signed Final enclave"
      VERBATIM)
    add_custom_command(
      OUTPUT "${ready_file}" "${ready_summary}" "${verified_file}"
      COMMAND "${ATFIELD_IMPLEMENT_ROOT}/build/pretouch/pretouch.ts" verify
              --profile-elf "$<TARGET_FILE:${enclave_target}>"
              --signed-profile-elf "${profile_signed}"
              --final-elf "${final_file}" --signed-final-elf "${signed_file}"
              --workset "${workset_file}" --fields "${fields_file}"
              --capacity-q "${protect_q}" --out-json "${verified_file}"
      COMMAND "${ATFIELD_IMPLEMENT_ROOT}/build/readiness/readiness.ts"
              --workset "${workset_file}" --fields "${fields_file}"
              --pretouch "${verified_file}"
              --final-elf "${final_file}" --signed-final-elf "${signed_file}"
              --out "${ready_file}" --out-json "${ready_summary}"
      DEPENDS "${signed_file}" "${workset_file}"
              "${ATFIELD_IMPLEMENT_ROOT}/build/pretouch/pretouch.ts"
              "${ATFIELD_IMPLEMENT_ROOT}/build/workset/workset.ts"
              "${ATFIELD_IMPLEMENT_ROOT}/build/readiness/readiness.ts"
      COMMENT "[SGX] verify Final and emit ECALL page-readiness table"
      VERBATIM)
    add_custom_target(${enclave_target}_signed ALL DEPENDS "${ready_file}")
  else()
    add_custom_command(
      OUTPUT "${signed_file}"
      COMMAND "${SGX_SDK_SIGN}" sign -key "${key_path}"
              -enclave "$<TARGET_FILE:${enclave_target}>"
              -out "${signed_file}" -config "${CONFIG_PATH}"
      COMMAND "${CMAKE_OBJCOPY}" --strip-all --keep-section=.note.sgxmeta
              "${signed_file}"
      DEPENDS ${enclave_target} "${key_path}" "${CONFIG_PATH}"
      COMMENT "[SGX] signing enclave ${signed_file}"
      VERBATIM)
    add_custom_target(${enclave_target}_signed ALL DEPENDS "${signed_file}")
  endif()

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
  if(ATFIELD_MODE STREQUAL protect)
    target_sources(host PRIVATE
      "${ATFIELD_IMPLEMENT_ROOT}/host/urts/atfield_readiness.cpp")
    target_include_directories(host PRIVATE
      "${ATFIELD_IMPLEMENT_ROOT}/host/urts")
    target_compile_definitions(host PRIVATE
      ATFIELD_PROTECT=1
      "ATFIELD_READY_PATH=\"${ready_file}\"")
  endif()
  target_link_libraries(host PRIVATE
    ${ARG_HOST_LIBRARIES} "${sgx_urts_library}" pthread)
  set(host_link_launcher
    "${CMAKE_COMMAND}" -E env "NIX_LDFLAGS=${enclave_nix_ldflags}")
  set_target_properties(host PROPERTIES
    C_LINKER_LAUNCHER "${host_link_launcher}"
    CXX_LINKER_LAUNCHER "${host_link_launcher}"
    BUILD_RPATH "${SGX_PSW_RUNTIME_DIRECTORIES}"
    INSTALL_RPATH "${SGX_PSW_RUNTIME_DIRECTORIES}")
  add_dependencies(host ${enclave_target}_signed)
endfunction()
