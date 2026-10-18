#include "sgxssl_cpu_profile.h"

#include <cpuid.h>
#include <stddef.h>
#include <stdint.h>

static uint64_t host_xgetbv(uint32_t index)
{
    uint32_t eax;
    uint32_t edx;
    __asm__ volatile("xgetbv" : "=a"(eax), "=d"(edx) : "c"(index));
    return ((uint64_t)edx << 32) | eax;
}

int sgxssl_cpu_profile_supported(void)
{
    if (__get_cpuid_max(0, NULL) < 0x12)
        return 0;

    uint32_t eax;
    uint32_t ebx;
    uint32_t ecx;
    uint32_t edx;
    __cpuid(0, eax, ebx, ecx, edx);
    if (ebx != 0x756e6547U || edx != 0x49656e69U || ecx != 0x6c65746eU)
        return 0;

    __cpuid_count(7, 0, eax, ebx, ecx, edx);
    if ((ebx & (UINT32_C(1) << 2)) == 0)
        return 0;
    const uint32_t leaf7_ebx = ebx;
    const uint32_t leaf7_ecx = ecx;

    __cpuid_count(0x12, 0, eax, ebx, ecx, edx);
    if ((eax & UINT32_C(1)) == 0)
        return 0;

    __cpuid_count(1, 0, eax, ebx, ecx, edx);
    if ((ecx & (UINT32_C(1) << 26)) == 0 ||
        (ecx & (UINT32_C(1) << 27)) == 0)
        return 0;
    const uint64_t host_xcr0 = host_xgetbv(0);
    const uint32_t leaf1_edx = edx;
    const uint32_t leaf1_ecx = ecx;

    __cpuid_count(0x12, 1, eax, ebx, ecx, edx);
    const uint64_t sgx_xfrm = ((uint64_t)edx << 32) | ecx;

    const sgxssl_cpu_capabilities cpu = {
        .leaf1_edx = leaf1_edx,
        .leaf1_ecx = leaf1_ecx,
        .leaf7_ebx = leaf7_ebx,
        .leaf7_ecx = leaf7_ecx,
        .xfrm = host_xcr0 & sgx_xfrm,
    };
    return sgxssl_cpu_profile_matches(&cpu);
}
