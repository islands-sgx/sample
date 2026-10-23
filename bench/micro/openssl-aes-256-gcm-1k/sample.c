#include "sample.h"

#include <openssl/aes.h>
#include <openssl/modes.h>

#include <stdint.h>
#include <string.h>

enum { RECORD_BYTES = 1024, KEY_BYTES = 32, IV_BYTES = 12, AAD_BYTES = 16, TAG_BYTES = 16 };

static AES_KEY aes_key;
static GCM128_CONTEXT *encrypt_ctx;
static GCM128_CONTEXT *decrypt_ctx;
static uint8_t active_key[KEY_BYTES];
static uint8_t iv[IV_BYTES];
static uint8_t aad[AAD_BYTES];
static uint8_t plaintext[RECORD_BYTES];
static uint8_t ciphertext[RECORD_BYTES];
static uint8_t recovered[RECORD_BYTES];
static uint8_t tag[TAG_BYTES];
static uint8_t first_tag[TAG_BYTES];
static uint32_t next_nonce;
static int key_ready;

int sample_fixture(void)
{
    for (size_t i = 0; i < 8; ++i)
        iv[i] = (uint8_t)(i * 17u + 3u);
    for (size_t i = 0; i < sizeof(aad); ++i)
        aad[i] = (uint8_t)(i * 11u + 5u);
    for (size_t i = 0; i < sizeof(plaintext); ++i)
        plaintext[i] = (uint8_t)(i * 13u + 19u);
    return 0;
}

int sample_secret(void)
{
    for (size_t i = 0; i < sizeof(active_key); ++i)
        active_key[i] = (uint8_t)(i * 29u + 7u);
    if (AES_set_encrypt_key(active_key, KEY_BYTES * 8, &aes_key) != 0)
        return -1;
    encrypt_ctx = CRYPTO_gcm128_new(&aes_key, (block128_f)AES_encrypt);
    decrypt_ctx = CRYPTO_gcm128_new(&aes_key, (block128_f)AES_encrypt);
    if (encrypt_ctx == NULL || decrypt_ctx == NULL)
        return -1;
    key_ready = 1;
    return 0;
}

int sample_input(uint64_t round)
{
    (void)round;
    return 0;
}

int sample_workload(void)
{
    if (!key_ready || next_nonce == UINT32_MAX)
        return -1;
    for (size_t i = 0; i < 4; ++i)
        iv[8 + i] = (uint8_t)(next_nonce >> (24u - 8u * i));

    CRYPTO_gcm128_setiv(encrypt_ctx, iv, sizeof(iv));
    if (CRYPTO_gcm128_aad(encrypt_ctx, aad, sizeof(aad)) != 0 ||
        CRYPTO_gcm128_encrypt(encrypt_ctx, plaintext, ciphertext, sizeof(plaintext)) < 0)
        return -1;
    CRYPTO_gcm128_tag(encrypt_ctx, tag, sizeof(tag));

    CRYPTO_gcm128_setiv(decrypt_ctx, iv, sizeof(iv));
    if (CRYPTO_gcm128_aad(decrypt_ctx, aad, sizeof(aad)) != 0 ||
        CRYPTO_gcm128_decrypt(decrypt_ctx, ciphertext, recovered, sizeof(ciphertext)) < 0 ||
        CRYPTO_gcm128_finish(decrypt_ctx, tag, sizeof(tag)) != 0 ||
        memcmp(recovered, plaintext, RECORD_BYTES) != 0)
        return -1;

    if (next_nonce == 0)
        memcpy(first_tag, tag, sizeof(first_tag));
    ++next_nonce;
    return 0;
}

int sample_output(uint8_t *buffer, size_t capacity, size_t *size)
{
    if (buffer == NULL || size == NULL || capacity < sizeof(first_tag) || next_nonce == 0)
        return -1;
    memcpy(buffer, first_tag, sizeof(first_tag));
    *size = sizeof(first_tag);
    return 0;
}

void sample_release(void)
{
    CRYPTO_gcm128_release(encrypt_ctx);
    CRYPTO_gcm128_release(decrypt_ctx);
    encrypt_ctx = NULL;
    decrypt_ctx = NULL;
    memset(&aes_key, 0, sizeof(aes_key));
    memset(active_key, 0, sizeof(active_key));
    memset(first_tag, 0, sizeof(first_tag));
    memset(tag, 0, sizeof(tag));
    key_ready = 0;
    next_nonce = 0;
}
