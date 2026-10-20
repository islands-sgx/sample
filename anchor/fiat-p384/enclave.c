/* Expose fiat-crypto P-384 field operations through ECALLs. */
#include "enclave_t.h"

#include <stdint.h>
#include <string.h>

/* Generated operations are static inline, so include their translation unit. */
#include "vendor/p384_64.c"

void fiat_p384_mul_export(uint64_t out[6], const uint64_t a[6],
                          const uint64_t b[6])
{
    fiat_p384_montgomery_domain_field_element out_fe;
    fiat_p384_montgomery_domain_field_element a_fe;
    fiat_p384_montgomery_domain_field_element b_fe;

    memcpy(a_fe, a, sizeof(a_fe));
    memcpy(b_fe, b, sizeof(b_fe));
    fiat_p384_mul(out_fe, a_fe, b_fe);
    memcpy(out, out_fe, sizeof(out_fe));
}

void fiat_p384_square_export(uint64_t out[6], const uint64_t a[6])
{
    fiat_p384_montgomery_domain_field_element out_fe;
    fiat_p384_montgomery_domain_field_element a_fe;

    memcpy(a_fe, a, sizeof(a_fe));
    fiat_p384_square(out_fe, a_fe);
    memcpy(out, out_fe, sizeof(out_fe));
}

void fiat_p384_to_montgomery_export(uint64_t out[6], const uint64_t a[6])
{
    fiat_p384_montgomery_domain_field_element out_fe;
    fiat_p384_non_montgomery_domain_field_element a_fe;

    memcpy(a_fe, a, sizeof(a_fe));
    fiat_p384_to_montgomery(out_fe, a_fe);
    memcpy(out, out_fe, sizeof(out_fe));
}

void fiat_p384_from_montgomery_export(uint64_t out[6], const uint64_t a[6])
{
    fiat_p384_non_montgomery_domain_field_element out_fe;
    fiat_p384_montgomery_domain_field_element a_fe;

    memcpy(a_fe, a, sizeof(a_fe));
    fiat_p384_from_montgomery(out_fe, a_fe);
    memcpy(out, out_fe, sizeof(out_fe));
}

void ecall_p384_mul(const uint64_t *a, const uint64_t *b, uint64_t *out)
{
    uint64_t tmp[6];
    uint64_t sq[6];
    uint64_t mont[6];
    uint64_t plain[6];

    fiat_p384_mul_export(tmp, a, b);
    fiat_p384_square_export(sq, tmp);
    fiat_p384_from_montgomery_export(plain, sq);
    fiat_p384_to_montgomery_export(mont, plain);
    fiat_p384_mul_export(out, mont, b);
}

void ecall_p384_mul_mont(const uint64_t *a, const uint64_t *b, uint64_t *out)
{
    fiat_p384_mul_export(out, a, b);
}

void ecall_p384_square_mont(const uint64_t *a, uint64_t *out)
{
    fiat_p384_square_export(out, a);
}

void ecall_p384_to_montgomery(const uint64_t *a, uint64_t *out)
{
    fiat_p384_to_montgomery_export(out, a);
}

void ecall_p384_from_montgomery(const uint64_t *a, uint64_t *out)
{
    fiat_p384_from_montgomery_export(out, a);
}
