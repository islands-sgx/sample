#include <stddef.h>
#include <stdint.h>

#include "sabd.h"
#include "enclave_t.h"
#include "sgx_error.h"

#ifndef SABD_MAX_HASH_TABLE_ORDER
#define SABD_MAX_HASH_TABLE_ORDER 13U
#endif

#ifndef SABD_MAX_IN_JIDS
#define SABD_MAX_IN_JIDS 10000U
#endif

sgx_status_t sabd_lookup_hash(const jid_t *in_jids, size_t in_jid_count,
                              const jid_t *ab_jids, uint32_t ab_jid_count,
                              volatile uint8_t *in_ab_jids_result);

sgx_status_t ecall_lookup_hash(const uint64_t *in_jids,
                               uint64_t in_jid_count,
                               const uint64_t *ab_jids,
                               uint32_t ab_jid_count,
                               uint8_t *in_ab_jids_result)
{
    if ((in_jid_count != 0 && in_jids == NULL) ||
        (ab_jid_count != 0 &&
         (ab_jids == NULL || in_ab_jids_result == NULL)))
        return SGX_ERROR_INVALID_PARAMETER;
    if (ab_jid_count == 0)
        return SGX_SUCCESS;
    if (in_jid_count > SABD_MAX_IN_JIDS ||
        ab_jid_count > (1U << SABD_MAX_HASH_TABLE_ORDER))
        return SGX_ERROR_INVALID_PARAMETER;

    return sabd_lookup_hash((const jid_t *)in_jids, (size_t)in_jid_count,
                            (const jid_t *)ab_jids, ab_jid_count,
                            (volatile uint8_t *)in_ab_jids_result);
}
