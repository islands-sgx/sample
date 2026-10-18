/* Expose Adam Langley's X25519 implementation as a raw RFC 7748 primitive. */
#include "Enclave_t.h"

#include <curve25519-donna.h>
#include <stdint.h>
#include <string.h>

void ecall_curve25519(const uint8_t *sk, const uint8_t *bp, uint8_t *out)
{
    /* curve25519_donna applies RFC 7748 scalar clamping. */
    if (curve25519_donna(out, sk, bp) != 0)
        memset(out, 0, 32);
}
