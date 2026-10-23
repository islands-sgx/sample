#include "bench_t.h"
#include "sample.h"

#include <stddef.h>
#include <stdint.h>

#define BENCH_MAX_RESULT_CAPACITY 4096U

static uint64_t cycles_before(void)
{
    uint32_t lo;
    uint32_t hi;

    __asm__ volatile("lfence\n\trdtsc\n\tlfence" : "=a"(lo), "=d"(hi) : : "memory");
    return ((uint64_t)hi << 32) | lo;
}

static uint64_t cycles_after(void)
{
    uint32_t lo;
    uint32_t hi;
    uint32_t aux;

    __asm__ volatile("rdtscp\n\tlfence" : "=a"(lo), "=d"(hi), "=c"(aux) : : "memory");
    return ((uint64_t)hi << 32) | lo;
}

ATFIELD static int protected_sample_workload(void)
{
    return sample_workload();
}

int fixture(void)
{
    return sample_fixture();
}

int secret(void)
{
    return sample_secret();
}

int result(uint8_t *buffer, size_t capacity, size_t *size)
{
    if (buffer == NULL || size == NULL || capacity == 0 || capacity > BENCH_MAX_RESULT_CAPACITY)
        return -1;
    return sample_output(buffer, capacity, size);
}

int input(uint64_t round)
{
    return sample_input(round);
}

int timing(uint64_t *cycles)
{
    uint64_t start;
    int status;

    if (cycles == NULL)
        return -1;
    start = cycles_before();
    status = protected_sample_workload();
    *cycles = cycles_after() - start;
    return status;
}

int release(void)
{
    sample_release();
    return 0;
}
