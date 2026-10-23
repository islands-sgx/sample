#include "sample.h"

#include <openssl/sha.h>

#include <stdint.h>
#include <string.h>

enum { MESSAGE_BYTES = 4096, DIGEST_BYTES = SHA256_DIGEST_LENGTH };

static uint8_t message[MESSAGE_BYTES];
static uint8_t digest[DIGEST_BYTES];
static uint64_t completed;
static int ready;

int sample_fixture(void)
{
    return 0;
}

int sample_secret(void)
{
    for (size_t i = 0; i < sizeof(message); ++i)
        message[i] = (uint8_t)(i * 29u + 7u);
    ready = 1;
    return 0;
}

int sample_input(uint64_t round)
{
    (void)round;
    return 0;
}

int sample_workload(void)
{
    SHA256_CTX ctx;

    if (!ready || SHA256_Init(&ctx) != 1 ||
        SHA256_Update(&ctx, message, sizeof(message)) != 1 ||
        SHA256_Final(digest, &ctx) != 1)
        return -1;
    ++completed;
    return 0;
}

int sample_output(uint8_t *buffer, size_t capacity, size_t *size)
{
    if (buffer == NULL || size == NULL || capacity < sizeof(digest) || completed == 0)
        return -1;
    memcpy(buffer, digest, sizeof(digest));
    *size = sizeof(digest);
    return 0;
}

void sample_release(void)
{
    memset(message, 0, sizeof(message));
    memset(digest, 0, sizeof(digest));
    completed = 0;
    ready = 0;
}
