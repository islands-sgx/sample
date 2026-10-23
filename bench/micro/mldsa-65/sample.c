#include "sample.h"

#include <mldsa_native.h>
#include <sgx_trts.h>

#include <string.h>

enum { MESSAGE_BYTES = 64 };

static const uint8_t pure_prefix[2] = {0, 0};
static uint8_t public_key[MLDSA65_PUBLICKEYBYTES];
static uint8_t secret_key[MLDSA65_SECRETKEYBYTES];
static uint8_t message[MESSAGE_BYTES];
static uint8_t coins[MLDSA_RNDBYTES];
static uint8_t signature[MLDSA65_BYTES];
static uint64_t verified_rounds;
static int key_ready;
static int coins_ready;

int sample_fixture(void)
{
    for (size_t i = 0; i < sizeof(message); ++i)
        message[i] = (uint8_t)(i * 17u + 3u);
    return 0;
}

int sample_secret(void)
{
    uint8_t seed[MLDSA_SEEDBYTES];
    int status;

    if (sgx_read_rand(seed, sizeof(seed)) != SGX_SUCCESS)
        return -1;
    status = PQCP_MLDSA_NATIVE_MLDSA65_keypair_internal(
        public_key, secret_key, seed);
    memset(seed, 0, sizeof(seed));
    if (status != 0)
        return -1;
    key_ready = 1;
    return 0;
}

int sample_input(uint64_t round)
{
    (void)round;
    coins_ready = 0;
    if (sgx_read_rand(coins, sizeof(coins)) != SGX_SUCCESS)
        return -1;
    coins_ready = 1;
    return 0;
}

int sample_workload(void)
{
    if (!key_ready || !coins_ready ||
        PQCP_MLDSA_NATIVE_MLDSA65_signature_internal(
            signature, message, sizeof(message), pure_prefix,
            sizeof(pure_prefix), coins, secret_key, 0) != 0 ||
        PQCP_MLDSA_NATIVE_MLDSA65_verify_internal(
            signature, message, sizeof(message), pure_prefix,
            sizeof(pure_prefix), public_key, 0) != 0)
        return -1;
    coins_ready = 0;
    ++verified_rounds;
    return 0;
}

int sample_output(uint8_t *buffer, size_t capacity, size_t *size)
{
    if (buffer == NULL || size == NULL || capacity < 1 || verified_rounds == 0)
        return -1;
    buffer[0] = 0xa5;
    *size = 1;
    return 0;
}

void sample_release(void)
{
    memset(secret_key, 0, sizeof(secret_key));
    memset(coins, 0, sizeof(coins));
    memset(signature, 0, sizeof(signature));
    key_ready = 0;
    coins_ready = 0;
    verified_rounds = 0;
}
