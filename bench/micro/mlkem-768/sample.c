#include "sample.h"

#include <mlkem_native.h>
#include <sgx_trts.h>

#include <string.h>

static uint8_t public_key[MLKEM768_PUBLICKEYBYTES];
static uint8_t secret_key[MLKEM768_SECRETKEYBYTES];
static uint8_t coins[MLKEM_SYMBYTES];
static uint8_t ciphertext[MLKEM768_CIPHERTEXTBYTES];
static uint8_t shared_enc[MLKEM_BYTES];
static uint8_t shared_dec[MLKEM_BYTES];
static uint64_t verified_rounds;
static int key_ready;
static int coins_ready;

int sample_fixture(void)
{
    return 0;
}

int sample_secret(void)
{
    uint8_t seed[2 * MLKEM_SYMBYTES];
    int status;

    if (sgx_read_rand(seed, sizeof(seed)) != SGX_SUCCESS)
        return -1;
    status = PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(
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
        PQCP_MLKEM_NATIVE_MLKEM768_enc_derand(
            ciphertext, shared_enc, public_key, coins) != 0 ||
        PQCP_MLKEM_NATIVE_MLKEM768_dec(
            shared_dec, ciphertext, secret_key) != 0 ||
        memcmp(shared_enc, shared_dec, sizeof(shared_enc)) != 0)
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
    memset(shared_enc, 0, sizeof(shared_enc));
    memset(shared_dec, 0, sizeof(shared_dec));
    key_ready = 0;
    coins_ready = 0;
    verified_rounds = 0;
}
