#include "Enclave_t.h"

#include <stdint.h>
#include <string.h>

int curve25519_donna(uint8_t *mypublic, const uint8_t *secret,
                     const uint8_t *basepoint);

int ecall_curve25519_shared_secret(const uint8_t *sk,
                                   const uint8_t *peer_pk, uint8_t *out)
{
    uint8_t aggregate = 0;

    if (curve25519_donna(out, sk, peer_pk) != 0)
        memset(out, 0, 32);
    for (uint32_t i = 0; i < 32; i++) {
        aggregate |= out[i];
    }
    return aggregate == 0 ? 1 : 0;
}
