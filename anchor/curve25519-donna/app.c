#include <stdio.h>
#include <string.h>

#include "enclave_u.h"
#include "sgx_urts.h"

#ifndef ENCLAVE_PATH
#define ENCLAVE_PATH "enclave.signed.so"
#endif

static void print_hex(const char *label, const uint8_t *p, size_t n)
{
    printf("%s:", label);
    for (size_t i = 0; i < n; i++) {
        printf(" %02x", p[i]);
    }
    printf("\n");
}

static int hex_eq(const uint8_t *a, const uint8_t *b, size_t n)
{
    return memcmp(a, b, n) == 0;
}

/* RFC 7748 §5.2 and §6.1 known-answer tests. */
static int run_kat(sgx_enclave_id_t eid)
{
    sgx_status_t st;
    uint8_t out[32];
    int failures = 0;

    /* RFC 7748 §5.2: X25519(k, u). */
    static const uint8_t rfc_sk[32] = {
        0xa5, 0x46, 0xe3, 0x6b, 0xf0, 0x52, 0x7c, 0x9d,
        0x3b, 0x16, 0x15, 0x4b, 0x82, 0x46, 0x5e, 0xdd,
        0x62, 0x14, 0x4c, 0x0a, 0xc1, 0xfc, 0x5a, 0x18,
        0x50, 0x6a, 0x22, 0x44, 0xba, 0x44, 0x9a, 0xc4,
    };
    static const uint8_t rfc_u[32] = {
        0xe6, 0xdb, 0x68, 0x67, 0x58, 0x30, 0x30, 0xdb,
        0x35, 0x94, 0xc1, 0xa4, 0x24, 0xb1, 0x5f, 0x7c,
        0x72, 0x66, 0x24, 0xec, 0x26, 0xb3, 0x35, 0x3b,
        0x10, 0xa9, 0x03, 0xa6, 0xd0, 0xab, 0x1c, 0x4c,
    };
    static const uint8_t rfc_out[32] = {
        0xc3, 0xda, 0x55, 0x37, 0x9d, 0xe9, 0xc6, 0x90,
        0x8e, 0x94, 0xea, 0x4d, 0xf2, 0x8d, 0x08, 0x4f,
        0x32, 0xec, 0xcf, 0x03, 0x49, 0x1c, 0x71, 0xf7,
        0x54, 0xb4, 0x07, 0x55, 0x77, 0xa2, 0x85, 0x52,
    };

    memset(out, 0, sizeof(out));
    st = ecall_curve25519(eid, rfc_sk, rfc_u, out);
    if (st != SGX_SUCCESS) {
        printf("FAIL: ecall_curve25519 §5.2 status=0x%x\n", (unsigned)st);
        return 1;
    }
    if (!hex_eq(out, rfc_out, 32)) {
        printf("FAIL: RFC7748 §5.2 X25519(k,u) mismatch\n");
        print_hex(" got", out, 32);
        print_hex(" exp", rfc_out, 32);
        failures++;
    } else {
        printf("PASS: RFC7748 §5.2 X25519(k,u)\n");
    }

    /* RFC 7748 §6.1: Alice public = X25519(a, 9). */
    static const uint8_t alice_sk[32] = {
        0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d,
        0x3c, 0x16, 0xc1, 0x72, 0x51, 0xb2, 0x66, 0x45,
        0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a,
        0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a,
    };
    static const uint8_t basepoint[32] = {9};
    static const uint8_t alice_pk[32] = {
        0x85, 0x20, 0xf0, 0x09, 0x89, 0x30, 0xa7, 0x54,
        0x74, 0x8b, 0x7d, 0xdc, 0xb4, 0x3e, 0xf7, 0x5a,
        0x0d, 0xbf, 0x3a, 0x0d, 0x26, 0x38, 0x1a, 0xf4,
        0xeb, 0xa4, 0xa9, 0x8e, 0xaa, 0x9b, 0x4e, 0x6a,
    };

    memset(out, 0, sizeof(out));
    st = ecall_curve25519(eid, alice_sk, basepoint, out);
    if (st != SGX_SUCCESS) {
        printf("FAIL: ecall_curve25519 Alice status=0x%x\n", (unsigned)st);
        return 1;
    }
    if (!hex_eq(out, alice_pk, 32)) {
        printf("FAIL: RFC7748 §6.1 Alice public mismatch\n");
        print_hex(" got", out, 32);
        print_hex(" exp", alice_pk, 32);
        failures++;
    } else {
        printf("PASS: RFC7748 §6.1 Alice public X25519(a,9)\n");
    }

    /* RFC 7748 §6.1: Bob public = X25519(b, 9). */
    static const uint8_t bob_sk[32] = {
        0x5d, 0xab, 0x08, 0x7e, 0x62, 0x4a, 0x8a, 0x4b,
        0x79, 0xe1, 0x7f, 0x8b, 0x83, 0x80, 0x0e, 0xe6,
        0x6f, 0x3b, 0xb1, 0x29, 0x26, 0x18, 0xb6, 0xfd,
        0x1c, 0x2f, 0x8b, 0x27, 0xff, 0x88, 0xe0, 0xeb,
    };
    static const uint8_t bob_pk[32] = {
        0xde, 0x9e, 0xdb, 0x7d, 0x7b, 0x7d, 0xc1, 0xb4,
        0xd3, 0x5b, 0x61, 0xc2, 0xec, 0xe4, 0x35, 0x37,
        0x3f, 0x83, 0x43, 0xc8, 0x5b, 0x78, 0x67, 0x4d,
        0xad, 0xfc, 0x7e, 0x14, 0x6f, 0x88, 0x2b, 0x4f,
    };

    memset(out, 0, sizeof(out));
    st = ecall_curve25519(eid, bob_sk, basepoint, out);
    if (st != SGX_SUCCESS) {
        printf("FAIL: ecall_curve25519 Bob status=0x%x\n", (unsigned)st);
        return 1;
    }
    if (!hex_eq(out, bob_pk, 32)) {
        printf("FAIL: RFC7748 §6.1 Bob public mismatch\n");
        print_hex(" got", out, 32);
        print_hex(" exp", bob_pk, 32);
        failures++;
    } else {
        printf("PASS: RFC7748 §6.1 Bob public X25519(b,9)\n");
    }

    /* RFC 7748 §6.1 shared secret. */
    static const uint8_t shared[32] = {
        0x4a, 0x5d, 0x9d, 0x5b, 0xa4, 0xce, 0x2d, 0xe1,
        0x72, 0x8e, 0x3b, 0xf4, 0x80, 0x35, 0x0f, 0x25,
        0xe0, 0x7e, 0x21, 0xc9, 0x47, 0xd1, 0x9e, 0x33,
        0x76, 0xf0, 0x9b, 0x3c, 0x1e, 0x16, 0x17, 0x42,
    };
    uint8_t shared_a[32], shared_b[32];
    int shared_status;

    memset(shared_a, 0, sizeof(shared_a));
    st = ecall_curve25519_shared_secret(eid, &shared_status, alice_sk, bob_pk,
                                        shared_a);
    if (st != SGX_SUCCESS) {
        printf("FAIL: checked shared_a status=0x%x\n", (unsigned)st);
        return 1;
    }
    if (shared_status != 0) {
        printf("FAIL: checked shared_a rejected valid peer key\n");
        failures++;
    }
    memset(shared_b, 0, sizeof(shared_b));
    st = ecall_curve25519_shared_secret(eid, &shared_status, bob_sk, alice_pk,
                                        shared_b);
    if (st != SGX_SUCCESS) {
        printf("FAIL: checked shared_b status=0x%x\n", (unsigned)st);
        return 1;
    }
    if (shared_status != 0) {
        printf("FAIL: checked shared_b rejected valid peer key\n");
        failures++;
    }
    if (!hex_eq(shared_a, shared, 32) || !hex_eq(shared_b, shared, 32) ||
        !hex_eq(shared_a, shared_b, 32)) {
        printf("FAIL: RFC7748 §6.1 shared secret mismatch\n");
        print_hex(" got_a", shared_a, 32);
        print_hex(" got_b", shared_b, 32);
        print_hex(" exp  ", shared, 32);
        failures++;
    } else {
        printf("PASS: RFC7748 §6.1 shared secret X25519(a,B)==X25519(b,A)\n");
    }

    /* RFC 7748 §6.1 permits rejecting an all-zero shared secret. */
    static const uint8_t zero_u[32] = {0};
    uint8_t rejected[32];

    memset(rejected, 0xa5, sizeof(rejected));
    st = ecall_curve25519_shared_secret(eid, &shared_status, alice_sk, zero_u,
                                        rejected);
    if (st != SGX_SUCCESS) {
        printf("FAIL: checked low-order input status=0x%x\n", (unsigned)st);
        return 1;
    }
    if (shared_status != 1 || !hex_eq(rejected, zero_u, 32)) {
        printf("FAIL: all-zero shared secret was not rejected\n");
        print_hex(" out", rejected, 32);
        failures++;
    } else {
        printf("PASS: RFC7748 §6.1 all-zero shared secret rejected\n");
    }

    if (failures == 0) {
        printf("KAT: all RFC7748 X25519 vectors PASS\n");
        return 0;
    }
    printf("KAT: %d check(s) FAILED\n", failures);
    return 1;
}

int main(int argc, char **argv)
{
    const char *enclave_path = (argc > 1) ? argv[1] : ENCLAVE_PATH;
    sgx_enclave_id_t eid = 0;
    sgx_status_t status = sgx_create_enclave(enclave_path, SGX_DEBUG_FLAG,
                                             NULL, NULL, &eid, NULL);
    if (status != SGX_SUCCESS) {
        fprintf(stderr, "sgx_create_enclave(%s) failed: 0x%x\n", enclave_path,
                (unsigned)status);
        return 1;
    }

    int kat = run_kat(eid);
    sgx_destroy_enclave(eid);
    if (kat != 0) {
        fprintf(stderr, "curve25519-donna KAT FAILED\n");
        return 1;
    }
    printf("curve25519-donna enclave OK (RFC7748 KAT)\n");
    return 0;
}
