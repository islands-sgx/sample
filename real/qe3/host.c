#include <sgx_urts.h>

#ifdef ATFIELD_PROTECT
#include <atfield_readiness_host.h>
#endif

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "enclave_u.h"

#ifndef ENCLAVE_PATH
#define ENCLAVE_PATH "enclave.signed.so"
#endif

#define KEY_ID_SIZE 32
#define PUBLIC_KEY_SIZE 64

static int hex_nibble(char ch)
{
    if (ch >= '0' && ch <= '9')
        return ch - '0';
    if (ch >= 'a' && ch <= 'f')
        return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F')
        return ch - 'A' + 10;
    return -1;
}

static int parse_key_id(const char *hex, uint8_t key_id[KEY_ID_SIZE])
{
    if (strlen(hex) != KEY_ID_SIZE * 2)
        return 0;

    for (size_t i = 0; i < KEY_ID_SIZE; ++i) {
        int high = hex_nibble(hex[2 * i]);
        int low = hex_nibble(hex[2 * i + 1]);
        if (high < 0 || low < 0)
            return 0;
        key_id[i] = (uint8_t)((high << 4) | low);
    }
    return 1;
}

static void print_usage(const char *program)
{
    printf("Usage: %s [--key-id HEX64] [--self-test]\n"
           "  --key-id HEX64  derive using exactly 32 bytes encoded as 64 hex digits\n"
           "  --self-test test all 32 single-byte key_id flips\n"
           "  --help          show this help\n"
           "Without --key-id, use the byte pattern 01, 02, ..., 20.\n",
           program);
}

static int derive(sgx_enclave_id_t enclave_id,
                  const uint8_t key_id[KEY_ID_SIZE],
                  uint8_t public_key[PUBLIC_KEY_SIZE])
{
    uint32_t result = UINT32_MAX;
    sgx_status_t status =
        ecall_get_attestation_key(enclave_id, &result, key_id, public_key);
    if (status != SGX_SUCCESS || result != 0) {
        fprintf(stderr, "attestation-key request failed: SGX=%#x QE3=%#x\n",
                (unsigned int)status, (unsigned int)result);
        return 0;
    }
    return 1;
}

static int check_repeated_key_id(sgx_enclave_id_t enclave_id,
                                 const uint8_t key_id[KEY_ID_SIZE],
                                 uint8_t baseline[PUBLIC_KEY_SIZE])
{
    uint8_t repeated[PUBLIC_KEY_SIZE];
    if (!derive(enclave_id, key_id, baseline) ||
        !derive(enclave_id, key_id, repeated))
        return 0;
    if (memcmp(baseline, repeated, sizeof(repeated)) != 0) {
        fprintf(stderr, "same key_id produced different public keys\n");
        return 0;
    }
    return 1;
}

static int check_first_byte_flip_distinct(
    sgx_enclave_id_t enclave_id, const uint8_t key_id[KEY_ID_SIZE],
    const uint8_t baseline[PUBLIC_KEY_SIZE])
{
    uint8_t flipped_key_id[KEY_ID_SIZE];
    uint8_t flipped[PUBLIC_KEY_SIZE];
    memcpy(flipped_key_id, key_id, sizeof(flipped_key_id));
    flipped_key_id[0] ^= 0x01;
    if (!derive(enclave_id, flipped_key_id, flipped))
        return 0;
    if (memcmp(flipped, baseline, sizeof(flipped)) == 0) {
        fprintf(stderr, "key_id byte 0 flip matched the baseline public key\n");
        return 0;
    }
    return 1;
}

static int check_single_byte_flip_distinct(
    sgx_enclave_id_t enclave_id, const uint8_t key_id[KEY_ID_SIZE],
    const uint8_t baseline[PUBLIC_KEY_SIZE])
{
    uint8_t flipped_key_id[KEY_ID_SIZE];
    uint8_t first[PUBLIC_KEY_SIZE];
    uint8_t repeated[PUBLIC_KEY_SIZE];

    for (size_t i = 0; i < KEY_ID_SIZE; ++i) {
        memcpy(flipped_key_id, key_id, sizeof(flipped_key_id));
        flipped_key_id[i] ^= 0x01;
        if (!derive(enclave_id, flipped_key_id, first) ||
            !derive(enclave_id, flipped_key_id, repeated))
            return 0;
        if (memcmp(first, repeated, sizeof(first)) != 0) {
            fprintf(stderr,
                    "key_id byte %zu flip produced a non-repeatable key\n",
                    i);
            return 0;
        }
        if (memcmp(first, baseline, sizeof(first)) == 0) {
            fprintf(stderr,
                    "key_id byte %zu flip matched the baseline public key\n",
                    i);
            return 0;
        }
    }
    return 1;
}

int main(int argc, char **argv)
{
    uint8_t key_id[KEY_ID_SIZE];
    int key_id_supplied = 0;
    int self_test = 0;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        }
        if (strcmp(argv[i], "--self-test") == 0) {
            self_test = 1;
            continue;
        }
        if (strcmp(argv[i], "--key-id") == 0 && i + 1 < argc) {
            if (!parse_key_id(argv[++i], key_id)) {
                fprintf(stderr, "--key-id requires exactly 64 hexadecimal digits\n");
                print_usage(argv[0]);
                return 2;
            }
            key_id_supplied = 1;
            continue;
        }
        fprintf(stderr, "invalid arguments\n");
        print_usage(argv[0]);
        return 2;
    }
    if (!key_id_supplied) {
        for (size_t i = 0; i < sizeof(key_id); ++i)
            key_id[i] = (uint8_t)(i + 1);
    }

    sgx_launch_token_t token = {0};
    int token_updated = 0;
    sgx_enclave_id_t enclave_id = 0;
    sgx_status_t status = sgx_create_enclave(
        ENCLAVE_PATH, SGX_DEBUG_FLAG, &token, &token_updated,
        &enclave_id, NULL);
    if (status != SGX_SUCCESS) {
        fprintf(stderr, "sgx_create_enclave failed: %#x\n",
                (unsigned int)status);
        return 1;
    }

    int failed = 0;
#ifdef ATFIELD_PROTECT
    if (!atfield_host_install_readiness(enclave_id))
        failed = 1;
#endif

    uint8_t baseline[PUBLIC_KEY_SIZE];
    if (!failed && !check_repeated_key_id(enclave_id, key_id, baseline))
        failed = 1;
    if (!failed && !check_first_byte_flip_distinct(enclave_id, key_id, baseline))
        failed = 1;
    if (!failed && self_test &&
        !check_single_byte_flip_distinct(enclave_id, key_id, baseline))
        failed = 1;

    sgx_status_t destroy_status = sgx_destroy_enclave(enclave_id);
    if (destroy_status != SGX_SUCCESS) {
        fprintf(stderr, "sgx_destroy_enclave failed: %#x\n",
                (unsigned int)destroy_status);
        failed = 1;
    }
    if (failed)
        return 1;
    puts(self_test ? "QE3 self-test: PASS"
                       : "QE3 functional checks: PASS");
    return 0;
}
