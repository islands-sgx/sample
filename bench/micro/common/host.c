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
#define MAX_WARMUP_ROUNDS 10000
#define ANSWER_CAPACITY 64

typedef struct {
    uint64_t iteration;
    uint64_t enclave_tsc_ticks;
    uint64_t host_ecall_ns;
} sample_row_t;

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

static int run_timing(sgx_enclave_id_t eid, uint64_t round, sample_row_t *row)
{
    struct timespec start;
    struct timespec end;
    sgx_status_t transport;
    int retval = 0;
    int clock_status;

    transport = input(eid, &retval, round);
    if (transport != SGX_SUCCESS || retval != 0) {
        report_ecall_error("input", transport, retval);
        return -1;
    }
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &start) != 0) {
        perror("clock_gettime start");
        return -1;
    }
    retval = 0;
    transport = timing(eid, &retval, &row->enclave_tsc_ticks);
    clock_status = clock_gettime(CLOCK_MONOTONIC_RAW, &end);
    if (transport != SGX_SUCCESS || retval != 0) {
        report_ecall_error("timing", transport, retval);
        return -1;
    }
    if (clock_status != 0) {
        perror("clock_gettime end");
        return -1;
    }
    row->iteration = round;
    row->host_ecall_ns = elapsed_ns(&start, &end);
    return 0;
}

int main(int argc, char **argv)
{
    uint64_t warmup_rounds = DEFAULT_WARMUP_ROUNDS;
    uint64_t measured_rounds = DEFAULT_MEASURED_ROUNDS;
    int cold = 0;
    sgx_launch_token_t token = {0};
    sgx_enclave_id_t eid = 0;
    sgx_status_t transport;
    int token_updated = 0;
    int retval = 0;
    int exit_code = EXIT_FAILURE;
    uint64_t round;
    sample_row_t *rows = NULL;
    uint8_t produced[ANSWER_CAPACITY];
    size_t produced_size = 0;
    size_t answer_size = 0;
    const uint8_t *answer;

    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
        warmup_rounds = PROFILE_WARMUP_ROUNDS;
        measured_rounds = PROFILE_MEASURED_ROUNDS;
    } else if (argc == 2 && strcmp(argv[1], "--cold") == 0) {
        cold = 1;
        warmup_rounds = 0;
        measured_rounds = 1;
    } else if (argc > 3 || (argc >= 2 && parse_count(argv[1], &warmup_rounds) != 0) ||
               (argc == 3 && parse_count(argv[2], &measured_rounds) != 0)) {
        fprintf(stderr, "usage: %s [--cold | --self-test | warmup [rounds]]\n", argv[0]);
        return EXIT_FAILURE;
    }
    if (measured_rounds == 0 || warmup_rounds > MAX_WARMUP_ROUNDS ||
        measured_rounds > SIZE_MAX / sizeof(*rows)) {
        fprintf(stderr, "invalid benchmark round count\n");
        return EXIT_FAILURE;
    }
    rows = calloc((size_t)measured_rounds, sizeof(*rows));
    if (rows == NULL) {
        perror("calloc sample rows");
        return EXIT_FAILURE;
    }

    answer = sample_answer(&answer_size);
    if (answer == NULL || answer_size > sizeof(produced)) {
        fprintf(stderr, "invalid known answer size: %zu\n", answer_size);
        goto finish_without_enclave;
    }

    transport =
        sgx_create_enclave(ENCLAVE_PATH, SGX_DEBUG_FLAG, &token, &token_updated, &eid, NULL);
    if (transport != SGX_SUCCESS) {
        fprintf(stderr, "sgx_create_enclave failed: 0x%08x\n", (unsigned int)transport);
        goto finish_without_enclave;
    }

#ifdef ATFIELD_PROTECT
    if (!atfield_host_install_readiness(eid)) {
        sgx_destroy_enclave(eid);
        goto finish_without_enclave;
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

    if (cold) {
        if (run_timing(eid, 0, &rows[0]) != 0)
            goto finish;
    } else {
        for (round = 0; round < warmup_rounds; ++round) {
            sample_row_t discarded;
            if (run_timing(eid, round, &discarded) != 0)
                goto finish;
        }
        for (round = 0; round < measured_rounds; ++round) {
            if (run_timing(eid, round, &rows[round]) != 0)
                goto finish;
        }
    }

    retval = 0;
    transport = result(eid, &retval, produced, sizeof(produced), &produced_size);
    if (transport != SGX_SUCCESS || retval != 0) {
        report_ecall_error("result", transport, retval);
        goto finish;
    }
    if (produced_size != answer_size || memcmp(produced, answer, answer_size) != 0) {
        fprintf(stderr, "known answer mismatch\n");
        goto finish;
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
finish_without_enclave:
    if (exit_code == EXIT_SUCCESS) {
        puts("sample,iteration,enclave_tsc_ticks,host_ecall_ns");
        for (round = 0; round < measured_rounds; ++round) {
            printf("%s,%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n", SAMPLE_NAME,
                   rows[round].iteration, rows[round].enclave_tsc_ticks,
                   rows[round].host_ecall_ns);
        }
    }
    free(rows);
    return exit_code;
}
