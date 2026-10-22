#define _POSIX_C_SOURCE 200809L

#include <sgx_urts.h>

#ifdef ATFIELD_PROTECT
#include <atfield_readiness_host.h>
#endif

#include "bench_u.h"

#include <errno.h>
#include <inttypes.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef ENCLAVE_PATH
#error "ENCLAVE_PATH must name the signed enclave"
#endif

#ifndef SAMPLE_NAME
#error "SAMPLE_NAME must name the benchmark sample"
#endif

#define DEFAULT_WARMUP_ROUNDS 100
#define DEFAULT_MEASURED_ROUNDS 1000
#define PROFILE_WARMUP_ROUNDS 1
#define PROFILE_MEASURED_ROUNDS 2
#define ANSWER_CAPACITY 64

const uint8_t *sample_answer(size_t *size);

static int parse_count(const char *text, uint64_t *value)
{
    char *end;
    unsigned long long parsed;

    if (text[0] == 0 || text[0] == '-')
        return -1;
    errno = 0;
    parsed = strtoull(text, &end, 10);
    if (errno == ERANGE || *end != 0)
        return -1;
    *value = (uint64_t)parsed;
    return 0;
}

static uint64_t elapsed_ns(const struct timespec *start, const struct timespec *end)
{
    uint64_t seconds = (uint64_t)(end->tv_sec - start->tv_sec);
    int64_t nanoseconds = end->tv_nsec - start->tv_nsec;

    if (nanoseconds < 0) {
        --seconds;
        nanoseconds += INT64_C(1000000000);
    }
    return seconds * UINT64_C(1000000000) + (uint64_t)nanoseconds;
}

static void report_ecall_error(const char *name, sgx_status_t transport, int retval)
{
    if (transport != SGX_SUCCESS)
        fprintf(stderr, "%s transport failed: 0x%08x\n", name, (unsigned int)transport);
    else
        fprintf(stderr, "%s failed: %d\n", name, retval);
}

int main(int argc, char **argv)
{
    uint64_t warmup_rounds = DEFAULT_WARMUP_ROUNDS;
    uint64_t measured_rounds = DEFAULT_MEASURED_ROUNDS;
    sgx_launch_token_t token = {0};
    sgx_enclave_id_t eid = 0;
    sgx_status_t transport;
    int token_updated = 0;
    int retval = 0;
    int exit_code = EXIT_FAILURE;
    uint64_t round;
    uint8_t produced[ANSWER_CAPACITY];
    size_t produced_size = 0;
    size_t answer_size = 0;
    const uint8_t *answer;

    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
        warmup_rounds = PROFILE_WARMUP_ROUNDS;
        measured_rounds = PROFILE_MEASURED_ROUNDS;
    } else if (argc > 3 || (argc >= 2 && parse_count(argv[1], &warmup_rounds) != 0) ||
               (argc == 3 && parse_count(argv[2], &measured_rounds) != 0)) {
        fprintf(stderr, "usage: %s [--self-test | warmup [rounds]]\n", argv[0]);
        return EXIT_FAILURE;
    }

    transport =
        sgx_create_enclave(ENCLAVE_PATH, SGX_DEBUG_FLAG, &token, &token_updated, &eid, NULL);
    if (transport != SGX_SUCCESS) {
        fprintf(stderr, "sgx_create_enclave failed: 0x%08x\n", (unsigned int)transport);
        return EXIT_FAILURE;
    }

#ifdef ATFIELD_PROTECT
    if (!atfield_host_install_readiness(eid)) {
        sgx_destroy_enclave(eid);
        return EXIT_FAILURE;
    }
#endif

    transport = fixture(eid, &retval);
    if (transport != SGX_SUCCESS || retval != 0) {
        report_ecall_error("fixture", transport, retval);
        goto finish;
    }

    retval = 0;
    transport = secret(eid, &retval);
    if (transport != SGX_SUCCESS || retval != 0) {
        report_ecall_error("secret", transport, retval);
        goto finish;
    }

    answer = sample_answer(&answer_size);
    if (answer == NULL || answer_size > sizeof(produced)) {
        fprintf(stderr, "invalid known answer size: %zu\n", answer_size);
        goto finish;
    }

    retval = 0;
    transport = verification(eid, &retval, produced, sizeof(produced), &produced_size);
    if (transport != SGX_SUCCESS || retval != 0) {
        report_ecall_error("verification", transport, retval);
        goto finish;
    }
    if (produced_size != answer_size || memcmp(produced, answer, answer_size) != 0) {
        fprintf(stderr, "known answer mismatch\n");
        goto finish;
    }

    retval = 0;
    transport = warmup(eid, &retval, warmup_rounds);
    if (transport != SGX_SUCCESS || retval != 0) {
        report_ecall_error("warmup", transport, retval);
        goto finish;
    }

    puts("sample,iteration,enclave_cycles,host_wall_ns");
    for (round = 0; round < measured_rounds; ++round) {
        struct timespec start;
        struct timespec end;
        uint64_t cycles = 0;
        int clock_status;

        retval = 0;
        transport = input(eid, &retval, round);
        if (transport != SGX_SUCCESS || retval != 0) {
            report_ecall_error("input", transport, retval);
            goto finish;
        }
        if (clock_gettime(CLOCK_MONOTONIC_RAW, &start) != 0) {
            perror("clock_gettime start");
            goto finish;
        }
        retval = 0;
        transport = timing(eid, &retval, &cycles);
        clock_status = clock_gettime(CLOCK_MONOTONIC_RAW, &end);
        if (transport != SGX_SUCCESS || retval != 0) {
            report_ecall_error("timing", transport, retval);
            goto finish;
        }
        if (clock_status != 0) {
            perror("clock_gettime end");
            goto finish;
        }
        printf("%s,%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n", SAMPLE_NAME, round, cycles,
               elapsed_ns(&start, &end));
    }
    exit_code = EXIT_SUCCESS;

finish:
    retval = 0;
    transport = release(eid, &retval);
    if (transport != SGX_SUCCESS || retval != 0) {
        report_ecall_error("release", transport, retval);
        exit_code = EXIT_FAILURE;
    }
    transport = sgx_destroy_enclave(eid);
    if (transport != SGX_SUCCESS) {
        fprintf(stderr, "sgx_destroy_enclave failed: 0x%08x\n", (unsigned int)transport);
        exit_code = EXIT_FAILURE;
    }
    return exit_code;
}
