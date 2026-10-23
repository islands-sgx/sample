#ifndef ATFIELD_BENCH_SAMPLE_H
#define ATFIELD_BENCH_SAMPLE_H

#include <stddef.h>
#include <stdint.h>

#ifndef ATFIELD
#define ATFIELD __attribute__((annotate("atfield.field.v1"), noinline))
#endif

int sample_fixture(void);
int sample_secret(void);
int sample_input(uint64_t round);
int sample_workload(void);
int sample_output(uint8_t *buffer, size_t capacity, size_t *size);
void sample_release(void);

#endif
