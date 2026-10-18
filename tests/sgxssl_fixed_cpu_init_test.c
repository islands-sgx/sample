#include <sgx_trts_exception.h>
#include <sgx_utils.h>

#include <assert.h>
#include <stddef.h>
#include <stdint.h>

#include "sgxssl_cpu_profile.h"

#ifndef TEST_XFRM
#define TEST_XFRM SGXSSL_CPU_XFRM
#endif

unsigned char sgxssl_test_cap_storage[20] __attribute__((aligned(16)));
__asm__(".globl OPENSSL_ia32cap_P\n"
        ".hidden OPENSSL_ia32cap_P\n"
        ".type OPENSSL_ia32cap_P,@object\n"
        ".set OPENSSL_ia32cap_P,sgxssl_test_cap_storage+4\n"
        ".size OPENSSL_ia32cap_P,16\n");
extern unsigned int OPENSSL_ia32cap_P[4] __attribute__((aligned(4)));

static sgx_report_t test_report;
static int registrations;
static sgx_exception_handler_t registered_handler;

const sgx_report_t *sgx_self_report(void)
{
    test_report.body.attributes.xfrm = TEST_XFRM;
    return &test_report;
}

void *sgx_register_exception_handler(int is_first_handler,
                                   sgx_exception_handler_t exception_handler)
{
    assert(is_first_handler == 1);
    assert(exception_handler != NULL);
    registrations++;
    registered_handler = exception_handler;
    return exception_handler;
}

void OPENSSL_cpuid_setup(void);
void init_exception_handler(uint32_t *cpuinfo_table);
void const_init_exception_handler(void);

static void assert_fixed_profile(void)
{
    assert(((uintptr_t)OPENSSL_ia32cap_P & 0xfU) == 4U);
    assert(OPENSSL_ia32cap_P[0] == 0x47808401U);
    assert(OPENSSL_ia32cap_P[1] == 0x7ed81203U);
    assert(OPENSSL_ia32cap_P[2] == 0xf02f0328U);
    assert(OPENSSL_ia32cap_P[3] == 0x00000700U);
    assert(OPENSSL_ia32cap_P[0] == SGXSSL_OPENSSL_CAP0);
    assert(OPENSSL_ia32cap_P[1] == SGXSSL_OPENSSL_CAP1);
    assert(OPENSSL_ia32cap_P[2] == SGXSSL_OPENSSL_CAP2);
    assert(OPENSSL_ia32cap_P[3] == SGXSSL_OPENSSL_CAP3);
}

int main(void)
{
    if ((TEST_XFRM & SGXSSL_CPU_XFRM) != SGXSSL_CPU_XFRM)
        return 77;

    assert(registrations == 1);
    assert(registered_handler != 0);
    assert_fixed_profile();

    OPENSSL_cpuid_setup();
    init_exception_handler(NULL);
    init_exception_handler((uint32_t *)0x1);
    assert_fixed_profile();
    assert(registrations == 1);
    return 0;
}
