#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sgx_urts.h"
#include "sqlite_enclave_u.h"

#ifdef ATFIELD_PROTECT
#include "../../common/atfield_readiness_host.h"
#endif

#ifndef ENCLAVE_PATH
#define ENCLAVE_PATH "enclave.signed.so"
#endif

static int fail(const char *msg, sgx_status_t st, sgx_status_t ret)
{
    fprintf(stderr, "FAIL: %s (transport=0x%x, ret=0x%x)\n", msg, (unsigned)st, (unsigned)ret);
    return 1;
}

int main(int argc, char **argv)
{
    size_t rows = 8;
    int full_suite = 0;
    int custom_op_mode = -1;
    int custom_query_mode = -1;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--rows") == 0 && i + 1 < argc) {
            rows = (size_t)strtoul(argv[++i], NULL, 10);
        } else if (strcmp(argv[i], "--full-tx-suite") == 0) {
            full_suite = 1;
        } else if (strcmp(argv[i], "--op-mode") == 0 && i + 1 < argc) {
            custom_op_mode = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--query-mode") == 0 && i + 1 < argc) {
            custom_query_mode = atoi(argv[++i]);
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            return 64;
        }
    }
    if (rows == 0 || rows > 16384) {
        fprintf(stderr, "Invalid --rows %zu\n", rows);
        return 64;
    }

    sgx_enclave_id_t eid = 0;
    sgx_launch_token_t token = {0};
    int updated = 0;
    const char *enclave_path = getenv("ATFIELD_ENCLAVE_PATH");
    if (!enclave_path || !*enclave_path)
        enclave_path = ENCLAVE_PATH;

    sgx_status_t st = sgx_create_enclave(enclave_path, SGX_DEBUG_FLAG, &token, &updated, &eid, NULL);
    if (st != SGX_SUCCESS)
        return fail("sgx_create_enclave", st, SGX_SUCCESS);

#ifdef ATFIELD_PROTECT
    if (!atfield_host_install_readiness(eid)) {
        sgx_destroy_enclave(eid);
        return 1;
    }
#endif

    int db_id = 0;
    sgx_status_t ret = SGX_ERROR_UNEXPECTED;
    st = ecall_db_open(eid, &ret, 0, &db_id);
    if (st != SGX_SUCCESS || ret != SGX_SUCCESS || db_id != 1) {
        sgx_destroy_enclave(eid);
        return fail("ecall_db_open", st, ret);
    }

    int *ids = (int *)calloc(rows, sizeof(int));
    int *vals = (int *)calloc(rows, sizeof(int));
    if (!ids || !vals) {
        free(ids);
        free(vals);
        sgx_destroy_enclave(eid);
        return 1;
    }
    long expected_sum = 0;
    for (size_t i = 0; i < rows; i++) {
        ids[i] = (int)(i * 7 + 10);
        vals[i] = (int)((i + 1) * 25);
        expected_sum += (vals[i] % 10000);
    }

    int affected = 0;
    st = ecall_db_exec_batch(eid, &ret, db_id, 0, ids, vals, rows, &affected);
    if (st != SGX_SUCCESS || ret != SGX_SUCCESS || affected <= 0) {
        free(ids);
        free(vals);
        sgx_destroy_enclave(eid);
        return fail("ecall_db_exec_batch insert", st, ret);
    }

    if (custom_op_mode >= 0) {
        int aff2 = 0;
        st = ecall_db_exec_batch(eid, &ret, db_id, custom_op_mode, ids, vals, rows, &aff2);
        if (st != SGX_SUCCESS || ret != SGX_SUCCESS) {
            free(ids);
            free(vals);
            sgx_destroy_enclave(eid);
            return fail("ecall_db_exec_batch custom_op_mode", st, ret);
        }
    }

    int out_cnt = 0;
    long out_sum = 0, out_metric = 0;
    int qmode = (custom_query_mode >= 0) ? custom_query_mode : 0;
    st = ecall_db_query_stats(eid, &ret, db_id, qmode, 0, &out_cnt, &out_sum, &out_metric);
    if (st != SGX_SUCCESS || ret != SGX_SUCCESS || out_cnt <= 0) {
        free(ids);
        free(vals);
        sgx_destroy_enclave(eid);
        return fail("ecall_db_query_stats", st, ret);
    }
    if (custom_op_mode < 0 && qmode == 0 && ((size_t)out_cnt != rows || out_sum != expected_sum)) {
        fprintf(stderr, "FAIL: sum/count mismatch: got cnt=%d sum=%ld, expected cnt=%zu sum=%ld\n",
                out_cnt, out_sum, rows, expected_sum);
        free(ids);
        free(vals);
        sgx_destroy_enclave(eid);
        return 1;
    }

    if (full_suite) {
        int aff_upd = 0, aff_sp = 0;
        st = ecall_db_exec_batch(eid, &ret, db_id, 1, ids, vals, rows, &aff_upd);
        if (st != SGX_SUCCESS || ret != SGX_SUCCESS || aff_upd != (int)rows) {
            free(ids);
            free(vals);
            sgx_destroy_enclave(eid);
            return fail("full_suite update+index", st, ret);
        }
        st = ecall_db_exec_batch(eid, &ret, db_id, 2, ids, vals, rows, &aff_sp);
        if (st != SGX_SUCCESS || ret != SGX_SUCCESS) {
            free(ids);
            free(vals);
            sgx_destroy_enclave(eid);
            return fail("full_suite savepoint+delete", st, ret);
        }
        for (int qm = 0; qm <= 2; qm++) {
            int c = 0;
            long s = 0, m = 0;
            st = ecall_db_query_stats(eid, &ret, db_id, qm, 0, &c, &s, &m);
            if (st != SGX_SUCCESS || ret != SGX_SUCCESS || c <= 0) {
                free(ids);
                free(vals);
                sgx_destroy_enclave(eid);
                return fail("full_suite query_mode", st, ret);
            }
        }
        st = ecall_db_exec_batch(eid, &ret, db_id, 99, ids, vals, rows, &aff_upd);
        if (st != SGX_SUCCESS || ret != SGX_ERROR_INVALID_PARAMETER) {
            free(ids);
            free(vals);
            sgx_destroy_enclave(eid);
            return fail("full_suite reject invalid op_mode", st, ret);
        }
        st = ecall_db_query_stats(eid, &ret, db_id, 99, 0, &out_cnt, &out_sum, &out_metric);
        if (st != SGX_SUCCESS || ret != SGX_ERROR_INVALID_PARAMETER) {
            free(ids);
            free(vals);
            sgx_destroy_enclave(eid);
            return fail("full_suite reject invalid query_mode", st, ret);
        }
    }

    free(ids);
    free(vals);
    sgx_destroy_enclave(eid);
    puts("SQLite transactional functional checks: PASS");
    return 0;
}
