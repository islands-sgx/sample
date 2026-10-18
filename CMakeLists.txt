cmake_minimum_required(VERSION 3.25)

project(islands-sgx-sample LANGUAGES C CXX)

set(ATFIELD_GROUP "anchor" CACHE STRING "Sample group: anchor or real")
set_property(CACHE ATFIELD_GROUP PROPERTY STRINGS anchor real)
if(NOT ATFIELD_GROUP MATCHES "^(anchor|real)$")
  message(FATAL_ERROR "ATFIELD_GROUP must be anchor or real")
endif()

set(ATFIELD_MODE "raw" CACHE STRING "Build mode: raw or anchor")
set_property(CACHE ATFIELD_MODE PROPERTY STRINGS raw anchor)
if(NOT ATFIELD_MODE MATCHES "^(raw|anchor)$")
  message(FATAL_ERROR "ATFIELD_MODE must be raw or anchor")
endif()

set(ATFIELD_SAMPLE "" CACHE STRING "Sample to build")
if(NOT ATFIELD_SAMPLE MATCHES "^[a-z0-9]+(-[a-z0-9]+)*$")
  message(FATAL_ERROR "ATFIELD_SAMPLE must use lower-case words separated by hyphens")
endif()
set(_ATFIELD_SAMPLE_LIST
    "${CMAKE_CURRENT_SOURCE_DIR}/${ATFIELD_GROUP}/${ATFIELD_SAMPLE}/CMakeLists.txt")
if(NOT EXISTS "${_ATFIELD_SAMPLE_LIST}")
  message(FATAL_ERROR "Unknown ${ATFIELD_GROUP} sample: ${ATFIELD_SAMPLE}")
endif()

if(CMAKE_BUILD_TYPE OR CMAKE_CONFIGURATION_TYPES)
  message(FATAL_ERROR "Sample profiles define optimization flags; leave CMAKE_BUILD_TYPE empty")
endif()
if(NOT CMAKE_LINKER OR NOT EXISTS "${CMAKE_LINKER}")
  message(FATAL_ERROR "CMAKE_LINKER must point to the pinned LLD")
endif()

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
set(ATFIELD_TEST_SIGNING_KEY
    "${CMAKE_SOURCE_DIR}/build/test-signing-key.pem"
    CACHE PATH "Shared SGX test-signing key")

include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/SgxEnclave.cmake")
sgx_find_sdk()
add_subdirectory("${ATFIELD_GROUP}/${ATFIELD_SAMPLE}")
