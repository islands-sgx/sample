#include "sample.h"

#include "yescrypt.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

static const uint8_t secret_password[32] = {
    0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64,
    0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64,
    0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64,
    0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72, 0x64,
};
static const uint8_t salt[32] = {
    0x78, 0x57, 0x8e, 0x5a, 0x5d, 0x63, 0xcb, 0x06, 0x78, 0x57, 0x8e,
    0x5a, 0x5d, 0x63, 0xcb, 0x06, 0x78, 0x57, 0x8e, 0x5a, 0x5d, 0x63,
    0xcb, 0x06, 0x78, 0x57, 0x8e, 0x5a, 0x5d, 0x63, 0xcb, 0x06,
};
static const yescrypt_params_t params = {
    .flags = YESCRYPT_RW_DEFAULTS,
    .N = 16384,
    .r = 1,
    .p = 1,
    .t = 0,
    .g = 0,
    .NROM = 0,
};
static yescrypt_local_t local;
static uint8_t active_password[32];
static uint8_t derived[32];
static int local_initialized;

int sample_fixture(void)
{
    if (local_initialized)
        return 0;
    if (yescrypt_init_local(&local) != 0)
        return -1;
    local_initialized = 1;
    return 0;
}

int sample_secret(void)
{
    memcpy(active_password, secret_password, sizeof(active_password));
    return 0;
}

int sample_vector(void)
{
    return 0;
}

int sample_input(uint64_t round)
{
    (void)round;
    return 0;
}

int sample_workload(void)
{
    if (!local_initialized)
        return -1;
    return yescrypt_kdf(NULL, &local, active_password, sizeof(active_password), salt,
                        sizeof(salt), &params, derived, sizeof(derived));
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
    memset(derived, 0, sizeof(derived));
    if (local_initialized) {
        yescrypt_free_local(&local);
        local_initialized = 0;
    }
}
