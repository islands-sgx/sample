#include <sgx_urts.h>

#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/obj_mac.h>

#include <array>
#include <cerrno>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <string>
#include <string.h>

#ifdef ATFIELD_PROTECT
#include <atfield_readiness_host.h>
#endif

#include "enclave_u.h"

#ifndef ENCLAVE_PATH
#define ENCLAVE_PATH "enclave.signed.so"
#endif

struct Failure : std::exception {};

[[noreturn]] static void fail(const char *message)
{
    std::fprintf(stderr, "%s\n", message);
    throw Failure{};
}

static void checked_transport(const char *op, sgx_status_t transport)
{
    if (transport != SGX_SUCCESS) {
        std::fprintf(stderr, "%s: transport=0x%08x\n", op,
                     static_cast<unsigned int>(transport));
        throw Failure{};
    }
}

static void checked_call(const char *op, sgx_status_t transport, int result)
{
    if (transport != SGX_SUCCESS || result != 0) {
        std::fprintf(stderr, "%s: transport=0x%08x result=%d\n", op,
                     static_cast<unsigned int>(transport), result);
        throw Failure{};
    }
}

static void rejected(const char *op, sgx_status_t transport, int result)
{
    if (transport != SGX_SUCCESS || result == 0) {
        std::fprintf(stderr,
                     "%s: expected enclave rejection; transport=0x%08x result=%d\n",
                     op, static_cast<unsigned int>(transport), result);
        throw Failure{};
    }
}

class Enclave {
  public:
    explicit Enclave(const char *path) : id_(0)
    {
        sgx_launch_token_t token = {0};
        int updated = 0;
        sgx_status_t status = sgx_create_enclave(
            path, SGX_DEBUG_FLAG, &token, &updated, &id_, nullptr);
        if (status != SGX_SUCCESS) {
            std::fprintf(stderr, "sgx_create_enclave: status=0x%08x\n",
                         static_cast<unsigned int>(status));
            throw Failure{};
        }
#ifdef ATFIELD_PROTECT
        if (!atfield_host_install_readiness(id_)) {
            (void)sgx_destroy_enclave(id_);
            id_ = 0;
            throw Failure{};
        }
#endif
    }

    Enclave(const Enclave &) = delete;
    Enclave &operator=(const Enclave &) = delete;

    ~Enclave()
    {
        destroy();
    }

    sgx_enclave_id_t get() const
    {
        return id_;
    }

    void destroy()
    {
        if (id_ != 0) {
            sgx_destroy_enclave(id_);
            id_ = 0;
        }
    }

  private:
    sgx_enclave_id_t id_;
};

static bool is_hex_length(const char *value, size_t expected)
{
    if (std::strlen(value) != expected)
        return false;
    for (size_t i = 0; i < expected; ++i) {
        if (std::isxdigit(static_cast<unsigned char>(value[i])) == 0)
            return false;
    }
    return true;
}

static void require_hex64(const char *name, const char *value)
{
    if (!is_hex_length(value, 64)) {
        std::fprintf(stderr, "%s: expected 64 hexadecimal digits\n", name);
        throw Failure{};
    }
}

static bool is_nonempty_hex(const char *value, size_t maximum)
{
    size_t length = std::strlen(value);
    if (length == 0 || length > maximum)
        return false;
    for (size_t i = 0; i < length; ++i) {
        if (std::isxdigit(static_cast<unsigned char>(value[i])) == 0)
            return false;
    }
    return true;
}

using Bignum = std::unique_ptr<BIGNUM, decltype(&BN_free)>;
using EcKey = std::unique_ptr<EC_KEY, decltype(&EC_KEY_free)>;
using EcPoint = std::unique_ptr<EC_POINT, decltype(&EC_POINT_free)>;
using EcdsaSignature = std::unique_ptr<ECDSA_SIG, decltype(&ECDSA_SIG_free)>;

static Bignum parse_hex_bignum(const char *text)
{
    BIGNUM *raw = nullptr;
    if (BN_hex2bn(&raw, text) <= 0)
        return Bignum(nullptr, &BN_free);
    return Bignum(raw, &BN_free);
}

static bool verify_signature(const char *pub_x, const char *pub_y,
                             const std::array<uint8_t, 32> &hash,
                             const char *sig_r, const char *sig_s)
{
    EcKey key(EC_KEY_new_by_curve_name(NID_secp256k1), &EC_KEY_free);
    if (!key)
        return false;

    const EC_GROUP *group = EC_KEY_get0_group(key.get());
    if (group == nullptr)
        return false;

    Bignum x = parse_hex_bignum(pub_x);
    Bignum y = parse_hex_bignum(pub_y);
    if (!x || !y)
        return false;

    EcPoint point(EC_POINT_new(group), &EC_POINT_free);
    if (!point)
        return false;
    if (EC_POINT_set_affine_coordinates(group, point.get(), x.get(), y.get(),
                                        nullptr) != 1)
        return false;
    if (EC_KEY_set_public_key(key.get(), point.get()) != 1)
        return false;
    if (EC_KEY_check_key(key.get()) != 1)
        return false;

    Bignum r = parse_hex_bignum(sig_r);
    Bignum s = parse_hex_bignum(sig_s);
    if (!r || !s)
        return false;

    EcdsaSignature signature(ECDSA_SIG_new(), &ECDSA_SIG_free);
    if (!signature)
        return false;
    if (ECDSA_SIG_set0(signature.get(), r.release(), s.release()) != 1)
        return false;

    return ECDSA_do_verify(hash.data(), static_cast<int>(hash.size()),
                           signature.get(), key.get()) == 1;
}

static void sign_and_verify(sgx_enclave_id_t eid, uint8_t *encrypted_key,
                            uint64_t encrypted_len, const char *pub_x,
                            const char *pub_y,
                            const std::array<uint8_t, 32> &hash,
                            const char *hash_hex_override = nullptr)
{
    static constexpr char kHex[] = "0123456789abcdef";
    std::array<char, 65> hash_hex_buffer{};
    for (size_t i = 0; i < hash.size(); ++i) {
        hash_hex_buffer[i * 2] = kHex[hash[i] >> 4];
        hash_hex_buffer[i * 2 + 1] = kHex[hash[i] & 0x0f];
    }
    const char *hash_hex = hash_hex_override != nullptr
                               ? hash_hex_override
                               : hash_hex_buffer.data();

    std::array<char, 1024> err_string{};
    std::array<char, 1024> sig_r{};
    std::array<char, 1024> sig_s{};
    uint8_t sig_v = 0;
    int result = 0;
    sgx_status_t transport = trustedEcdsaSign(
        eid, &result, err_string.data(), encrypted_key, encrypted_len,
        hash_hex, sig_r.data(), sig_s.data(), &sig_v, 16);
    checked_call("trustedEcdsaSign", transport, result);

    if (sig_v > 3)
        fail("trustedEcdsaSign: invalid recovery value");
    if (!is_nonempty_hex(sig_r.data(), 64) ||
        !is_nonempty_hex(sig_s.data(), 64))
        fail("trustedEcdsaSign: malformed hexadecimal signature");
    if (!verify_signature(pub_x, pub_y, hash, sig_r.data(), sig_s.data()))
        fail("trustedEcdsaSign: host ECDSA verification failed");
}

// ECDSA cases from tests/integration/keys/ECDSAIntegrationTests.cpp.
static constexpr char kTestHashHex[] =
    "3F891FDA3704F0368DAB65FA81EBE616F4AA2A0854995DA4DC0B59D2CADBD64F";

static uint8_t hex_value(char c)
{
    if (c >= '0' && c <= '9')
        return static_cast<uint8_t>(c - '0');
    if (c >= 'a' && c <= 'f')
        return static_cast<uint8_t>(c - 'a' + 10);
    if (c >= 'A' && c <= 'F')
        return static_cast<uint8_t>(c - 'A' + 10);
    fail("invalid hexadecimal digit in test hash");
}

static std::array<uint8_t, 32> decode_hash_hex(const char *hex)
{
    require_hex64("test hash", hex);
    std::array<uint8_t, 32> hash{};
    for (size_t i = 0; i < hash.size(); ++i)
        hash[i] = static_cast<uint8_t>((hex_value(hex[i * 2]) << 4) |
                                       hex_value(hex[i * 2 + 1]));
    return hash;
}

static void test_keygen_and_sign(sgx_enclave_id_t eid)
{
    std::array<char, 1024> err_string{};
    std::array<uint8_t, 1024> encrypted_key{};
    std::array<char, 1024> pub_x{};
    std::array<char, 1024> pub_y{};
    uint64_t encrypted_len = 0;
    int exportable = 0;
    int result = 0;

    sgx_status_t transport = trustedGenerateEcdsaKey(
        eid, &result, err_string.data(), &exportable, encrypted_key.data(),
        &encrypted_len, pub_x.data(), pub_y.data());
    checked_call("trustedGenerateEcdsaKey", transport, result);
    if (encrypted_len == 0 || encrypted_len > encrypted_key.size())
        fail("trustedGenerateEcdsaKey: invalid encrypted length");
    require_hex64("pub_key_x", pub_x.data());
    require_hex64("pub_key_y", pub_y.data());

    const auto hash = decode_hash_hex(kTestHashHex);
    for (int i = 0; i < 50; ++i)
        sign_and_verify(eid, encrypted_key.data(), encrypted_len, pub_x.data(),
                        pub_y.data(), hash, kTestHashHex);
}

static void test_public_key(sgx_enclave_id_t eid)
{
    std::array<char, 1024> err_string{};
    std::array<uint8_t, 1024> encrypted_key{};
    std::array<char, 1024> pub_x{};
    std::array<char, 1024> pub_y{};
    uint64_t encrypted_len = 0;
    int exportable = 0;
    int result = 0;

    sgx_status_t transport = trustedGenerateEcdsaKey(
        eid, &result, err_string.data(), &exportable, encrypted_key.data(),
        &encrypted_len, pub_x.data(), pub_y.data());
    checked_call("trustedGenerateEcdsaKey", transport,
                 result);
    if (encrypted_len == 0 || encrypted_len > encrypted_key.size())
        fail("trustedGenerateEcdsaKey: invalid encrypted length");

    std::array<char, 1024> received_pub_x{};
    std::array<char, 1024> received_pub_y{};
    transport = trustedGetPublicEcdsaKey(
        eid, &result, err_string.data(), encrypted_key.data(), encrypted_len,
        received_pub_x.data(), received_pub_y.data());
    checked_call("trustedGetPublicEcdsaKey", transport, result);
    if (std::strcmp(received_pub_x.data(), pub_x.data()) != 0 ||
        std::strcmp(received_pub_y.data(), pub_y.data()) != 0)
        fail("trustedGetPublicEcdsaKey: public key changed");
}

static void run_self_tests(sgx_enclave_id_t eid)
{
    test_keygen_and_sign(eid);
    test_public_key(eid);
}

static void expect_sign_rejection(sgx_enclave_id_t eid,
                                  uint8_t *encrypted_key,
                                  uint64_t encrypted_len, const char *hash)
{
    std::array<char, 1024> err_string{};
    std::array<char, 1024> sig_r{};
    std::array<char, 1024> sig_s{};
    uint8_t sig_v = 0;
    int result = 0;
    sgx_status_t transport = trustedEcdsaSign(
        eid, &result, err_string.data(), encrypted_key, encrypted_len, hash,
        sig_r.data(), sig_s.data(), &sig_v, 16);
    rejected("trustedEcdsaSign", transport, result);
}

static uint64_t parse_positive(const char *text, const char *name)
{
    if (text == nullptr || *text == '\0' || *text == '-' || *text == '+') {
        std::fprintf(stderr, "%s must be a positive integer\n", name);
        throw Failure{};
    }

    errno = 0;
    char *end = nullptr;
    unsigned long long value = std::strtoull(text, &end, 10);
    if (errno == ERANGE || end == text || *end != '\0' || value == 0 ||
        value > std::numeric_limits<uint64_t>::max()) {
        std::fprintf(stderr, "%s must be a positive integer\n", name);
        throw Failure{};
    }
    return static_cast<uint64_t>(value);
}

struct Options {
    uint64_t requests = 1001;
    bool self_test = false;
};

static void usage(const char *program)
{
    std::fprintf(stderr,
                 "usage: %s [--requests N] [--self-test]\n", program);
}

static Options parse_options(int argc, char **argv)
{
    Options options;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--requests") == 0 && i + 1 < argc) {
            options.requests = parse_positive(argv[++i], "--requests");
        } else if (std::strcmp(argv[i], "--self-test") == 0) {
            options.self_test = true;
        } else {
            usage(argv[0]);
            throw Failure{};
        }
    }
    return options;
}

static int run(const Options &options)
{
    std::array<uint8_t, 1024> sealed_sek{};
    std::array<uint8_t, 1024> encrypted_key{};
    std::array<char, 65> backup{};
    std::array<char, 1024> err_string{};
    std::array<char, 1024> pub_x{};
    std::array<char, 1024> pub_y{};
    uint64_t sealed_len = 0;
    uint64_t encrypted_len = 0;
    int result = 0;

    Enclave enclave(ENCLAVE_PATH);
    sgx_enclave_id_t eid = enclave.get();

    checked_transport("trustedEnclaveInit", trustedEnclaveInit(eid, 2));

    sgx_status_t transport = trustedGenerateSEK(
        eid, &result, err_string.data(), sealed_sek.data(), &sealed_len,
        backup.data());
    checked_call("trustedGenerateSEK", transport, result);
    explicit_bzero(backup.data(), backup.size());
    if (sealed_len == 0 || sealed_len > sealed_sek.size())
        fail("trustedGenerateSEK: invalid sealed length");

    if (options.self_test) {
        run_self_tests(eid);
        checked_transport("trustedEnclaveClear", trustedEnclaveClear(eid));
        enclave.destroy();
        std::printf("sgxwallet self-test: PASS\n");
        return 0;
    }

    int exportable = 0;
    transport = trustedGenerateEcdsaKey(
        eid, &result, err_string.data(), &exportable, encrypted_key.data(),
        &encrypted_len, pub_x.data(), pub_y.data());
    checked_call("trustedGenerateEcdsaKey", transport, result);
    if (encrypted_len == 0 || encrypted_len > encrypted_key.size())
        fail("trustedGenerateEcdsaKey: invalid encrypted length");
    require_hex64("pub_key_x", pub_x.data());
    require_hex64("pub_key_y", pub_y.data());

    std::array<char, 1024> public_x{};
    std::array<char, 1024> public_y{};
    transport = trustedGetPublicEcdsaKey(
        eid, &result, err_string.data(), encrypted_key.data(), encrypted_len,
        public_x.data(), public_y.data());
    checked_call("trustedGetPublicEcdsaKey", transport, result);
    if (std::strcmp(public_x.data(), pub_x.data()) != 0 ||
        std::strcmp(public_y.data(), pub_y.data()) != 0)
        fail("trustedGetPublicEcdsaKey: public key changed");

    for (uint64_t i = 0; i < options.requests; ++i) {
        std::array<uint8_t, 32> hash{};
        for (size_t j = 0; j < hash.size(); ++j)
            hash[j] = static_cast<uint8_t>((i + j + 1) & 0xff);
        sign_and_verify(eid, encrypted_key.data(), encrypted_len, pub_x.data(),
                        pub_y.data(), hash);
    }

    std::array<uint8_t, 32> rejected_hash{};
    for (size_t i = 0; i < rejected_hash.size(); ++i)
        rejected_hash[i] = static_cast<uint8_t>(i + 1);

    uint8_t original = encrypted_key[0];
    encrypted_key[0] ^= 0xff;
    expect_sign_rejection(eid, encrypted_key.data(), encrypted_len,
                          "000102030405060708090a0b0c0d0e0f"
                          "101112131415161718191a1b1c1d1e1f");
    encrypted_key[0] = original;
    sign_and_verify(eid, encrypted_key.data(), encrypted_len, pub_x.data(),
                    pub_y.data(), rejected_hash);

    expect_sign_rejection(eid, encrypted_key.data(), encrypted_len, "not-hex");
    sign_and_verify(eid, encrypted_key.data(), encrypted_len, pub_x.data(),
                    pub_y.data(), rejected_hash);

    checked_transport("trustedEnclaveClear", trustedEnclaveClear(eid));
    enclave.destroy();

    Enclave restored(ENCLAVE_PATH);
    sgx_enclave_id_t restored_id = restored.get();
    checked_transport("trustedEnclaveInit",
                      trustedEnclaveInit(restored_id, 2));
    transport = trustedSetSEK(restored_id, &result, err_string.data(),
                            sealed_sek.data());
    checked_call("trustedSetSEK", transport, result);
    sign_and_verify(restored_id, encrypted_key.data(), encrypted_len,
                    pub_x.data(), pub_y.data(), rejected_hash);
    checked_transport("trustedEnclaveClear", trustedEnclaveClear(restored_id));
    restored.destroy();

    std::printf("sgxwallet ECDSA functional checks: PASS\n");
    return 0;
}

int main(int argc, char **argv)
{
    try {
        Options options = parse_options(argc, argv);
        return run(options);
    } catch (const Failure &) {
        return 1;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}

extern "C" uint64_t oc_realloc(void *optr, size_t osz, size_t nsz)
{
    (void)osz;
    return reinterpret_cast<uint64_t>(std::realloc(optr, nsz));
}

extern "C" void oc_free(void *optr, size_t sz)
{
    (void)sz;
    std::free(optr);
}
