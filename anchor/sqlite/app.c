#include <stdio.h>

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
    int retval = -1;

    status = sgx_create_enclave(enclave_path, SGX_DEBUG_FLAG, NULL, NULL, &eid,
                                NULL);
    if (status != SGX_SUCCESS) {
        fprintf(stderr, "sgx_create_enclave(%s) failed: 0x%x\n", enclave_path,
                (unsigned)status);
        return 1;
    }

    status = ecall_sql_selftest(eid, &retval);
    if (status != SGX_SUCCESS) {
        fprintf(stderr, "ecall_sql_selftest bridge failed: 0x%x\n",
                (unsigned)status);
        sgx_destroy_enclave(eid);
        return 1;
    }

    if (retval != 0) {
        fprintf(stderr,
                "SQL KAT FAIL: ecall_sql_selftest returned %d "
                "(expected aggregate=300, row_number=4, "
                "date=2024-03-01)\n",
                retval);
        sgx_destroy_enclave(eid);
        return 1;
    }

    printf("SQL KAT PASS: aggregate=300, row_number=4, "
           "date=2024-03-01 inside enclave\n");
    printf("ecall_sql_selftest returned 0\n");

    sgx_destroy_enclave(eid);
    return 0;
}
