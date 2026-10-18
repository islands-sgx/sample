#include "sgxssl_cpu_profile.h"

#include <assert.h>
#include <stddef.h>
#include <stdint.h>

int main(void)
{
    static const uint32_t required[4] = {
        SGXSSL_CPU_LEAF1_EDX,
        SGXSSL_CPU_LEAF1_ECX,
        SGXSSL_CPU_LEAF7_EBX,
        SGXSSL_CPU_LEAF7_ECX,
    };
    const sgxssl_cpu_capabilities exact = {
        .leaf1_edx = SGXSSL_CPU_LEAF1_EDX,
        .leaf1_ecx = SGXSSL_CPU_LEAF1_ECX,
        .leaf7_ebx = SGXSSL_CPU_LEAF7_EBX,
        .leaf7_ecx = SGXSSL_CPU_LEAF7_ECX,
        .xfrm = SGXSSL_CPU_XFRM,
    };
    const sgxssl_cpu_capabilities extra = {
        .leaf1_edx = UINT32_MAX,
        .leaf1_ecx = UINT32_MAX,
        .leaf7_ebx = UINT32_MAX,
        .leaf7_ecx = UINT32_MAX,
        .xfrm = UINT64_MAX,
    };

    assert(!sgxssl_cpu_profile_matches(NULL));
    assert(sgxssl_cpu_profile_matches(&exact));
    assert(sgxssl_cpu_profile_matches(&extra));

    for (int word = 0; word < 4; word++) {
        for (unsigned int bit = 0; bit < 32; bit++) {
            if ((required[word] & (UINT32_C(1) << bit)) == 0)
                continue;
            sgxssl_cpu_capabilities missing = exact;
            uint32_t *fields[] = {
                &missing.leaf1_edx,
                &missing.leaf1_ecx,
                &missing.leaf7_ebx,
                &missing.leaf7_ecx,
            };
            *fields[word] &= ~(UINT32_C(1) << bit);
            assert(!sgxssl_cpu_profile_matches(&missing));
        }
    }

    for (unsigned int bit = 0; bit < 64; bit++) {
        if ((SGXSSL_CPU_XFRM & (UINT64_C(1) << bit)) == 0)
            continue;
        sgxssl_cpu_capabilities missing = exact;
        missing.xfrm &= ~(UINT64_C(1) << bit);
        assert(!sgxssl_cpu_profile_matches(&missing));
    }
    return 0;
}
