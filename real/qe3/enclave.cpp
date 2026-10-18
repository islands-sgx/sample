#include <cstdint>
#include <cstring>

#include "qe3_enclave_t.h"
#include "sgx_aex_notify_region.h"
#include "sgx_key.h"
#include "sgx_report.h"
#include "sgx_secure_align.h"
#include "sgx_tcrypto.h"
#include "sgx_trts.h"
#include "sgx_tseal.h"
#include "sgx_utils.h"
#include "user_types.h"

#include "attestation_key.inc"

static sgx_status_t register_aex_region_handler_once()
{
    static const sgx_status_t status = sgx_register_aex_region_handler();
    return status;
}

extern "C" uint32_t ecall_get_attestation_key(const uint8_t *key_id,
                                               uint8_t *public_key)
{
    if (key_id == nullptr || public_key == nullptr)
        return REFQE3_ERROR_INVALID_PARAMETER;

    if (register_aex_region_handler_once() != SGX_SUCCESS)
        return REFQE3_ERROR_UNEXPECTED;

    sgx_ec256_private_t private_key = {};
    sgx_ec256_public_t derived_public_key = {};
    const auto result = get_att_key_based_from_seal_key(
        &private_key, &derived_public_key,
        reinterpret_cast<const sgx_key_id_t *>(key_id));

    if (result == REFQE3_SUCCESS)
        memcpy(public_key, &derived_public_key, sizeof(derived_public_key));
    else
        memset_s(public_key, 64, 0, 64);

    memset_s(&private_key, sizeof(private_key), 0, sizeof(private_key));
    return static_cast<uint32_t>(result);
}
