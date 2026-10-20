#include <stdio.h>
#include <string.h>

#include "enclave_u.h"
#include "sgx_urts.h"

#ifndef ENCLAVE_PATH
#define ENCLAVE_PATH "enclave.signed.so"
#endif

static int limbs_eq(const uint64_t a[6], const uint64_t b[6])
{
    return memcmp(a, b, 6 * sizeof(uint64_t)) == 0;
}

static void print_limbs(const char *label, const uint64_t v[6])
{
    printf("%s:", label);
    for (size_t i = 0; i < 6; i++) {
        printf(" %016llx", (unsigned long long)v[i]);
    }
    printf("\n");
}

/* Algebraic KAT for fiat P-384 Montgomery arithmetic. */
static int run_kat(sgx_enclave_id_t eid)
{
    sgx_status_t st;
    /* Small non-Montgomery field elements (well below p). */
    const uint64_t x[6] = {0x1111111111111111ULL, 0x2222222222222222ULL,
                           0x3333333333333333ULL, 0, 0, 0};
    const uint64_t y[6] = {0xabcdef0123456789ULL, 0x1010101010101010ULL,
                           0x55aa55aa55aa55aaULL, 1, 0, 0};
    const uint64_t one[6] = {1, 0, 0, 0, 0, 0};

    uint64_t x_m[6], y_m[6], one_m[6];
    uint64_t rt[6], id[6], ab[6], ba[6], sq[6], aa[6];
    uint64_t chain_out[6];

    memset(x_m, 0, sizeof(x_m));
    memset(y_m, 0, sizeof(y_m));
    memset(one_m, 0, sizeof(one_m));
    memset(rt, 0, sizeof(rt));
    memset(id, 0, sizeof(id));
    memset(ab, 0, sizeof(ab));
    memset(ba, 0, sizeof(ba));
    memset(sq, 0, sizeof(sq));
    memset(aa, 0, sizeof(aa));
    memset(chain_out, 0, sizeof(chain_out));

    st = ecall_p384_to_montgomery(eid, x, x_m);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_to_montgomery(x) status=0x%04x\n",
               (unsigned)st);
        return 10;
    }
    st = ecall_p384_to_montgomery(eid, y, y_m);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_to_montgomery(y) status=0x%04x\n",
               (unsigned)st);
        return 11;
    }
    st = ecall_p384_to_montgomery(eid, one, one_m);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_to_montgomery(1) status=0x%04x\n",
               (unsigned)st);
        return 12;
    }

    /* (1) Round-trip */
    st = ecall_p384_from_montgomery(eid, x_m, rt);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_from_montgomery status=0x%04x\n",
               (unsigned)st);
        return 13;
    }
    if (!limbs_eq(rt, x)) {
        printf("KAT FAIL: from(to(x)) != x\n");
        print_limbs("  x ", x);
        print_limbs("  rt", rt);
        return 20;
    }
    printf("KAT (1) round-trip from(to(x)) == x: PASS\n");

    /* (2) Multiplicative identity in Montgomery domain */
    st = ecall_p384_mul_mont(eid, one_m, x_m, id);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_mul_mont(1,x) status=0x%04x\n",
               (unsigned)st);
        return 14;
    }
    if (!limbs_eq(id, x_m)) {
        printf("KAT FAIL: mul(to_mont(1), to_mont(x)) != to_mont(x)\n");
        print_limbs("  x_m", x_m);
        print_limbs("  id ", id);
        return 21;
    }
    printf("KAT (2) mul(to_mont(1), to_mont(x)) == to_mont(x): PASS\n");

    /* (3) Commutativity */
    st = ecall_p384_mul_mont(eid, x_m, y_m, ab);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_mul_mont(x,y) status=0x%04x\n",
               (unsigned)st);
        return 15;
    }
    st = ecall_p384_mul_mont(eid, y_m, x_m, ba);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_mul_mont(y,x) status=0x%04x\n",
               (unsigned)st);
        return 16;
    }
    if (!limbs_eq(ab, ba)) {
        printf("KAT FAIL: mul(x,y) != mul(y,x)\n");
        print_limbs("  xy", ab);
        print_limbs("  yx", ba);
        return 22;
    }
    printf("KAT (3) mul(x,y) == mul(y,x): PASS\n");

    /* (4) square(A) == mul(A, A) */
    st = ecall_p384_square_mont(eid, x_m, sq);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_square_mont status=0x%04x\n",
               (unsigned)st);
        return 17;
    }
    st = ecall_p384_mul_mont(eid, x_m, x_m, aa);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_mul_mont(x,x) status=0x%04x\n",
               (unsigned)st);
        return 18;
    }
    if (!limbs_eq(sq, aa)) {
        printf("KAT FAIL: square(x) != mul(x,x)\n");
        print_limbs("  sq", sq);
        print_limbs("  aa", aa);
        return 23;
    }
    printf("KAT (4) square(x) == mul(x,x): PASS\n");

    /* Smoke-test the combined operation. */
    st = ecall_p384_mul(eid, x_m, y_m, chain_out);
    if (st != SGX_SUCCESS) {
        printf("KAT FAIL: ecall_p384_mul chain status=0x%04x\n",
               (unsigned)st);
        return 19;
    }
    /* Reject a silent no-op. */
    {
        int nonzero = 0;
        for (size_t i = 0; i < 6; i++) {
            if (chain_out[i] != 0) {
                nonzero = 1;
                break;
            }
        }
        if (!nonzero) {
            printf("KAT FAIL: chain ecall returned all-zero (unexpected)\n");
            return 24;
        }
    }
    print_limbs("combined operation", chain_out);
    printf("KAT (5) combined operation non-zero: PASS\n");

    printf("KAT PASS\n");
    return 0;
}

int main(int argc, char **argv)
{
    const char *enclave_path = (argc > 1) ? argv[1] : ENCLAVE_PATH;
    sgx_enclave_id_t eid = 0;
    sgx_status_t status = sgx_create_enclave(enclave_path, SGX_DEBUG_FLAG,
        NULL, NULL, &eid, NULL);
    if (status != SGX_SUCCESS) {
        printf("sgx_create_enclave failed: 0x%04x\n", (unsigned)status);
        return 1;
    }

    int kat = run_kat(eid);
    sgx_destroy_enclave(eid);
    if (kat != 0) {
        printf("fiat_p384_app: KAT failed (code %d)\n", kat);
        return kat;
    }
    return 0;
}
