if(NOT DEFINED KEY_PATH OR NOT DEFINED OPENSSL_EXECUTABLE)
  message(FATAL_ERROR "KEY_PATH and OPENSSL_EXECUTABLE are required")
endif()

get_filename_component(key_directory "${KEY_PATH}" DIRECTORY)
file(MAKE_DIRECTORY "${key_directory}")
file(LOCK "${KEY_PATH}.lock" GUARD PROCESS TIMEOUT 300 RESULT_VARIABLE lock_result)
if(NOT lock_result STREQUAL "0")
  message(FATAL_ERROR "Unable to lock signing key ${KEY_PATH}: ${lock_result}")
endif()

if(EXISTS "${KEY_PATH}")
  file(SIZE "${KEY_PATH}" key_size)
  if(key_size GREATER 0)
    return()
  endif()
endif()

set(temporary_key "${KEY_PATH}.tmp")
file(REMOVE "${temporary_key}")
execute_process(
  COMMAND "${OPENSSL_EXECUTABLE}" genrsa -3 -out "${temporary_key}" 3072
  RESULT_VARIABLE openssl_result)
if(NOT openssl_result EQUAL 0)
  file(REMOVE "${temporary_key}")
  message(FATAL_ERROR "OpenSSL failed to generate signing key: ${openssl_result}")
endif()

file(CHMOD "${temporary_key}" PERMISSIONS OWNER_READ OWNER_WRITE)
file(RENAME "${temporary_key}" "${KEY_PATH}" RESULT rename_result)
if(NOT rename_result STREQUAL "0")
  file(REMOVE "${temporary_key}")
  message(FATAL_ERROR "Unable to publish signing key ${KEY_PATH}: ${rename_result}")
endif()
