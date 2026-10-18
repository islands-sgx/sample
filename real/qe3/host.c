#include <sgx_urts.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "qe3_enclave_u.h"

static int derive(sgx_enclave_id_t enclave_id, const uint8_t key_id[32],
                  uint8_t public_key[64])
{
    uint32_t result = UINT32_MAX;
    sgx_status_t status =
        ecall_get_attestation_key(enclave_id, &result, key_id, public_key);
    if (status != SGX_SUCCESS || result != 0) {
        fprintf(stderr, "attestation-key request failed: SGX=%#x QE3=%#x\n",
                (unsigned int)status, (unsigned int)result);
        return 1;
    }
    return 0;
}

int main(void)
{
    sgx_launch_token_t token = {0};
    int token_updated = 0;
    sgx_enclave_id_t enclave_id = 0;
    sgx_status_t status = sgx_create_enclave(
        "enclave.signed.so", SGX_DEBUG_FLAG, &token, &token_updated,
        &enclave_id, NULL);
    if (status != SGX_SUCCESS) {
        fprintf(stderr, "sgx_create_enclave failed: %#x\n",
                (unsigned int)status);
        return 1;
    }

    uint8_t key_id[32];
    uint8_t different_key_id[32];
    uint8_t first_public_key[64];
    uint8_t repeated_public_key[64];
    uint8_t different_public_key[64];
    for (size_t i = 0; i < sizeof(key_id); ++i)
        key_id[i] = (uint8_t)(i + 1);
    memcpy(different_key_id, key_id, sizeof(key_id));
    different_key_id[0] ^= 1;

    int failed = derive(enclave_id, key_id, first_public_key) != 0 ||
                 derive(enclave_id, key_id, repeated_public_key) != 0 ||
                 derive(enclave_id, different_key_id,
                        different_public_key) != 0;
    if (!failed &&
        (memcmp(first_public_key, repeated_public_key,
                sizeof(first_public_key)) != 0 ||
         memcmp(first_public_key, different_public_key,
                sizeof(first_public_key)) == 0)) {
        fprintf(stderr, "attestation-key derivation checks failed\n");
        failed = 1;
    }

    sgx_status_t destroy_status = sgx_destroy_enclave(enclave_id);
    if (destroy_status != SGX_SUCCESS) {
        fprintf(stderr, "sgx_destroy_enclave failed: %#x\n",
                (unsigned int)destroy_status);
        failed = 1;
    }
    if (failed)
        return 1;
    puts("QE3 functional checks: PASS");
    return 0;
}
