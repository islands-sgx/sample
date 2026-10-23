#ifndef SGXSSL_CPU_PROFILE_H
#define SGXSSL_CPU_PROFILE_H

#include <stdint.h>

#define SGXSSL_CPU_PROFILE_NAME "intel-avx512-aes"

/* FPU, CMOV, MMX, FXSR, SSE and SSE2. */
#define SGXSSL_CPU_LEAF1_EDX                                             \
    ((UINT32_C(1) << 0) | (UINT32_C(1) << 15) | (UINT32_C(1) << 23) |    \
     (UINT32_C(1) << 24) | (UINT32_C(1) << 25) | (UINT32_C(1) << 26))

/* SSE3, PCLMUL, SSSE3, FMA, SSE4, MOVBE, POPCNT, AES, XSAVE, AVX and RDRAND. */
#define SGXSSL_CPU_LEAF1_ECX                                             \
    ((UINT32_C(1) << 0) | (UINT32_C(1) << 1) | (UINT32_C(1) << 9) |      \
     (UINT32_C(1) << 12) | (UINT32_C(1) << 19) | (UINT32_C(1) << 20) |   \
     (UINT32_C(1) << 22) | (UINT32_C(1) << 23) | (UINT32_C(1) << 25) |   \
     (UINT32_C(1) << 26) | (UINT32_C(1) << 27) | (UINT32_C(1) << 28) |   \
     (UINT32_C(1) << 29) | (UINT32_C(1) << 30))

/* BMI1/2, AVX2, ERMS, AVX512F/DQ/IFMA/CD/BW/VL, RDSEED, ADX and SHA. */
#define SGXSSL_CPU_LEAF7_EBX                                             \
    ((UINT32_C(1) << 3) | (UINT32_C(1) << 5) | (UINT32_C(1) << 8) |      \
     (UINT32_C(1) << 9) | (UINT32_C(1) << 16) | (UINT32_C(1) << 17) |    \
     (UINT32_C(1) << 18) | (UINT32_C(1) << 19) | (UINT32_C(1) << 21) |   \
     (UINT32_C(1) << 28) | (UINT32_C(1) << 29) | (UINT32_C(1) << 30) |   \
     (UINT32_C(1) << 31))

/* GFNI, VAES and VPCLMULQDQ. */
#define SGXSSL_CPU_LEAF7_ECX                                             \
    ((UINT32_C(1) << 8) | (UINT32_C(1) << 9) | (UINT32_C(1) << 10))

#define SGXSSL_CPU_XFRM UINT64_C(0xe7)

/* OpenSSL repurposes EDX[30] for Intel and EDX[10] for initialized state. */
#define SGXSSL_OPENSSL_CAP0                                             \
    (SGXSSL_CPU_LEAF1_EDX | (UINT32_C(1) << 30) | (UINT32_C(1) << 10))
#define SGXSSL_OPENSSL_CAP1 SGXSSL_CPU_LEAF1_ECX
#define SGXSSL_OPENSSL_CAP2 SGXSSL_CPU_LEAF7_EBX
#define SGXSSL_OPENSSL_CAP3 SGXSSL_CPU_LEAF7_ECX

typedef struct {
    uint32_t leaf1_edx;
    uint32_t leaf1_ecx;
    uint32_t leaf7_ebx;
    uint32_t leaf7_ecx;
    uint64_t xfrm;
} sgxssl_cpu_capabilities;

static inline int
sgxssl_cpu_profile_matches(const sgxssl_cpu_capabilities *cpu)
{
    return cpu != 0 &&
           (cpu->leaf1_edx & SGXSSL_CPU_LEAF1_EDX) == SGXSSL_CPU_LEAF1_EDX &&
           (cpu->leaf1_ecx & SGXSSL_CPU_LEAF1_ECX) == SGXSSL_CPU_LEAF1_ECX &&
           (cpu->leaf7_ebx & SGXSSL_CPU_LEAF7_EBX) == SGXSSL_CPU_LEAF7_EBX &&
           (cpu->leaf7_ecx & SGXSSL_CPU_LEAF7_ECX) == SGXSSL_CPU_LEAF7_ECX &&
           (cpu->xfrm & SGXSSL_CPU_XFRM) == SGXSSL_CPU_XFRM;
}

#ifdef __cplusplus
extern "C" {
#endif

int sgxssl_cpu_profile_supported(void);
void sgxssl_initialize_cpu_profile(void);

#ifdef __cplusplus
}
#endif

#endif
