#include <stdio.h>
#include <string.h>

#include "Enclave_u.h"
#include "sgx_urts.h"

#ifndef ENCLAVE_PATH
#define ENCLAVE_PATH "enclave.signed.so"
#endif

int main(int argc, char **argv)
{
    const char *enclave_path = (argc > 1) ? argv[1] : ENCLAVE_PATH;
    sgx_enclave_id_t eid = 0;
    sgx_status_t status;
    int failures = -1;

    status = sgx_create_enclave(enclave_path, SGX_DEBUG_FLAG, NULL, NULL, &eid,
                                NULL);
    if (status != SGX_SUCCESS) {
        printf("sgx_create_enclave failed: 0x%04x\n", (unsigned)status);
        return 1;
    }

    status = ecall_yescrypt_selftest(eid, &failures);
    if (status != SGX_SUCCESS) {
        printf("ecall_yescrypt_selftest failed: status=0x%04x\n",
               (unsigned)status);
        sgx_destroy_enclave(eid);
        return 2;
    }

    if (failures != 0) {
        printf("KAT FAIL: %d vector(s) mismatched or errored\n", failures);
        sgx_destroy_enclave(eid);
        return 3;
    }

    printf("KAT PASS: yescrypt selftest (YESCRYPT_DEFAULTS + WORM + scrypt)\n");
    sgx_destroy_enclave(eid);
    return 0;
}
