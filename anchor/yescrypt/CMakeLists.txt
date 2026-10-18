find_path(
  YESCRYPT_SGX_ROOT
  NAMES include/yescrypt.h
  HINTS ENV YESCRYPT_SGX_ROOT
  NO_DEFAULT_PATH
  REQUIRED)

sgx_add_sample(
  NAME yescrypt
  EDL Enclave.edl
  PROFILE DEBUG
  SOURCES enclave.c
  HOST_SOURCES app.c
  INCLUDE_DIRECTORIES "${YESCRYPT_SGX_ROOT}/include"
  TRUSTED_LIBRARIES "${YESCRYPT_SGX_ROOT}/lib/libyescrypt-sgx.a")
