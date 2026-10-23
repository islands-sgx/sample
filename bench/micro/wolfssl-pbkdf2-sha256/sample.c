#include "sample.h"

#include <wolfssl/wolfcrypt/hmac.h>
#include <wolfssl/wolfcrypt/pwdbased.h>

#include <string.h>

#define ITERATION_COUNT 16384

static const byte secret_password[32] = {
    0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64,
    0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64,
    0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64,
    0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64,
};
static const byte salt[32] = {
    0x78, 0x57, 0x8e, 0x5a, 0x5d, 0x63, 0xcb, 0x06, 0x78, 0x57, 0x8e,
    0x5a, 0x5d, 0x63, 0xcb, 0x06, 0x78, 0x57, 0x8e, 0x5a, 0x5d, 0x63,
    0xcb, 0x06, 0x78, 0x57, 0x8e, 0x5a, 0x5d, 0x63, 0xcb, 0x06,
};
static byte active_password[32];
static byte derived[32];

int sample_fixture(void)
{
    return 0;
}

int sample_secret(void)
{
    memcpy(active_password, secret_password, sizeof(active_password));
    return 0;
}

int sample_input(uint64_t round)
{
    (void)round;
    return 0;
}

int sample_workload(void)
{
    return wc_PBKDF2(derived, active_password, sizeof(active_password), salt, sizeof(salt), ITERATION_COUNT,
                     sizeof(derived), WC_SHA256);
}

int sample_output(uint8_t *buffer, size_t capacity, size_t *size)
{
    if (buffer == NULL || size == NULL || capacity < sizeof(derived))
        return -1;
    memcpy(buffer, derived, sizeof(derived));
    *size = sizeof(derived);
    return 0;
}

void sample_release(void)
{
    memset(active_password, 0, sizeof(active_password));
}
