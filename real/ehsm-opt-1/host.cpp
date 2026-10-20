#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <sgx_urts.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <limits>
#include <new>
#include <string>
#include <string.h>

#include <fcntl.h>
#include <unistd.h>

#ifdef ATFIELD_PROTECT
#include <atfield_readiness_host.h>
#endif

#include "datatypes.h"
#include "enclave_u.h"
#include "sgxssl_cpu_profile.h"

#ifndef ENCLAVE_PATH
#define ENCLAVE_PATH "enclave.signed.so"
#endif

static const char *g_domain_key_path = "domain-key.sealed";

struct Failure : std::exception {};

[[noreturn]] static void fail_status(const char *op, sgx_status_t transport,
                                     sgx_status_t result)
{
    std::fprintf(stderr, "%s: transport=0x%08x result=0x%08x\n", op,
                 static_cast<unsigned int>(transport),
                 static_cast<unsigned int>(result));
    throw Failure{};
}

void checked(const char *op, sgx_status_t transport, sgx_status_t result)
{
    if (transport != SGX_SUCCESS || result != SGX_SUCCESS)
        fail_status(op, transport, result);
}

void rejected(const char *op, sgx_status_t transport, sgx_status_t result)
{
    if (transport != SGX_SUCCESS || result == SGX_SUCCESS)
        fail_status(op, transport, result);
}

static void expected_invalid_parameter(const char *op,
                                       sgx_status_t transport,
                                       sgx_status_t result)
{
    if (transport != SGX_SUCCESS || result != SGX_ERROR_INVALID_PARAMETER)
        fail_status(op, transport, result);
}

template <class T> class Buffer {
  public:
    explicit Buffer(size_t payload) : data_(nullptr), size_(0)
    {
        if (payload > std::numeric_limits<size_t>::max() - sizeof(T))
            throw std::bad_alloc();
        size_ = sizeof(T) + payload;
        data_ = static_cast<T *>(std::calloc(1, size_));
        if (data_ == nullptr) {
            size_ = 0;
            throw std::bad_alloc();
        }
    }

    ~Buffer() { clear(); }

    Buffer(const Buffer &) = delete;
    Buffer &operator=(const Buffer &) = delete;

    Buffer(Buffer &&other) noexcept : data_(other.data_), size_(other.size_)
    {
        other.data_ = nullptr;
        other.size_ = 0;
    }

    Buffer &operator=(Buffer &&other) noexcept
    {
        if (this != &other) {
            clear();
            data_ = other.data_;
            size_ = other.size_;
            other.data_ = nullptr;
            other.size_ = 0;
        }
        return *this;
    }

    T *get() { return data_; }
    const T *get() const { return data_; }
    size_t size() const { return size_; }

    void resize(size_t payload)
    {
        if (payload > std::numeric_limits<size_t>::max() - sizeof(T))
            throw std::bad_alloc();
        size_t new_size = sizeof(T) + payload;
        if (new_size == size_)
            return;

        T *next = static_cast<T *>(std::calloc(1, new_size));
        if (next == nullptr)
            throw std::bad_alloc();
        if (data_ != nullptr) {
            std::memcpy(next, data_, size_ < new_size ? size_ : new_size);
            clear();
        }
        data_ = next;
        size_ = new_size;
    }

  private:
    void clear() noexcept
    {
        if (data_ != nullptr) {
            explicit_bzero(data_, size_);
            std::free(data_);
            data_ = nullptr;
        }
        size_ = 0;
    }

    T *data_;
    size_t size_;
};

using Data = Buffer<ehsm_data_t>;
using Key = Buffer<ehsm_keyblob_t>;

static Data data_buffer(size_t payload)
{
    if (payload > std::numeric_limits<uint32_t>::max())
        throw std::bad_alloc();
    Data data(payload);
    data.get()->datalen = static_cast<uint32_t>(payload);
    return data;
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

    ~Enclave()
    {
        if (id_ != 0)
            sgx_destroy_enclave(id_);
    }

    Enclave(const Enclave &) = delete;
    Enclave &operator=(const Enclave &) = delete;

    sgx_enclave_id_t id() const { return id_; }

    sgx_status_t close() noexcept
    {
        if (id_ == 0)
            return SGX_SUCCESS;
        sgx_enclave_id_t id = id_;
        id_ = 0;
        return sgx_destroy_enclave(id);
    }

  private:
    sgx_enclave_id_t id_;
};

static void require_equal(const char *op, const Data &actual,
                          const Data &expected)
{
    if (actual.get()->datalen != expected.get()->datalen ||
        std::memcmp(actual.get()->data, expected.get()->data,
                    expected.get()->datalen) != 0) {
        std::fprintf(stderr, "%s: output mismatch\n", op);
        throw Failure{};
    }
}

static void fill_data(Data &data, uint8_t seed)
{
    for (uint32_t i = 0; i < data.get()->datalen; i++)
        data.get()->data[i] = static_cast<uint8_t>(seed + i * 31U);
}

static constexpr uint32_t kAesGcm256KeyBytes = 32;
static constexpr uint32_t kAesGcmOverheadBytes =
    EH_AES_GCM_IV_SIZE + EH_AES_GCM_MAC_SIZE;
static constexpr uint32_t kAesGcm256KeyBlobBytes = EH_AES_GCM_256_SIZE;

Key create_key(sgx_enclave_id_t eid)
{
    Key key(kAesGcm256KeyBlobBytes);
    key.get()->metadata.keyspec = EH_AES_GCM_256;
    key.get()->metadata.origin = EH_INTERNAL_KEY;
    key.get()->metadata.keyusage = EH_KEYUSAGE_ENCRYPT_DECRYPT;
    key.get()->keybloblen = kAesGcm256KeyBlobBytes;

    sgx_status_t result = SGX_ERROR_UNEXPECTED;
    sgx_status_t transport = enclave_create_key(
        eid, &result, key.get(), key.size());
    checked("create_key", transport, result);
    return key;
}

Data encrypt(sgx_enclave_id_t eid, Key &key, Data &aad, Data &plain)
{
    Data out = data_buffer(plain.get()->datalen + kAesGcmOverheadBytes);
    sgx_status_t r = SGX_ERROR_UNEXPECTED;
    auto s = enclave_encrypt(eid, &r, key.get(), key.size(), aad.get(),
                             aad.size(), plain.get(), plain.size(), out.get(),
                             out.size());
    checked("encrypt", s, r);
    return out;
}

static constexpr size_t kCanaryBytes = 16;
static constexpr uint8_t kCanaryByte = 0xA5;

static void verify_canary(const char *step, const uint8_t *buf, size_t offset, size_t count)
{
    for (size_t i = 0; i < count; i++) {
        if (buf[offset + i] != kCanaryByte) {
            std::fprintf(stderr, "%s: boundary canary overwritten at +%zu (0x%02x != 0x%02x)\n",
                         step, i, buf[offset + i], kCanaryByte);
            throw Failure{};
        }
    }
}

Data decrypt(sgx_enclave_id_t eid, Key &key, Data &aad, Data &cipher)
{
    if (cipher.get()->datalen <= kAesGcmOverheadBytes)
        throw Failure{};
    uint32_t expected_len = cipher.get()->datalen - kAesGcmOverheadBytes;
    Data out_with_canary = data_buffer(expected_len + kCanaryBytes);
    std::memset(out_with_canary.get()->data, kCanaryByte, expected_len + kCanaryBytes);
    out_with_canary.get()->datalen = expected_len;
    uint32_t exact_abi_size = APPEND_SIZE_TO_DATA_T(expected_len);
    sgx_status_t r = SGX_ERROR_UNEXPECTED;
    auto s = enclave_decrypt(eid, &r, key.get(), key.size(), aad.get(),
                             aad.size(), cipher.get(), cipher.size(),
                             out_with_canary.get(), exact_abi_size);
    checked("decrypt", s, r);
    if (out_with_canary.get()->datalen != expected_len) {
        std::fprintf(stderr, "decrypt: unexpected output datalen %u != %u\n",
                     out_with_canary.get()->datalen, expected_len);
        throw Failure{};
    }
    verify_canary("decrypt exact canary", out_with_canary.get()->data, expected_len, kCanaryBytes);
    Data clean = data_buffer(expected_len);
    std::memcpy(clean.get()->data, out_with_canary.get()->data, expected_len);
    return clean;
}

Data decrypt_oversized_capacity(sgx_enclave_id_t eid, Key &key, Data &aad, Data &cipher, uint32_t extra_cap)
{
    if (cipher.get()->datalen <= kAesGcmOverheadBytes)
        throw Failure{};
    uint32_t expected_len = cipher.get()->datalen - kAesGcmOverheadBytes;
    uint32_t over_cap = expected_len + extra_cap;
    Data out_with_canary = data_buffer(over_cap + kCanaryBytes);
    std::memset(out_with_canary.get()->data, kCanaryByte, over_cap + kCanaryBytes);
    out_with_canary.get()->datalen = over_cap;
    uint32_t over_abi_size = APPEND_SIZE_TO_DATA_T(over_cap);
    sgx_status_t r = SGX_ERROR_UNEXPECTED;
    auto s = enclave_decrypt(eid, &r, key.get(), key.size(), aad.get(),
                             aad.size(), cipher.get(), cipher.size(),
                             out_with_canary.get(), over_abi_size);
    checked("decrypt oversized capacity", s, r);
    if (out_with_canary.get()->datalen != expected_len) {
        std::fprintf(stderr, "decrypt oversized: datalen not normalized (%u != %u)\n",
                     out_with_canary.get()->datalen, expected_len);
        throw Failure{};
    }
    verify_canary("decrypt oversized canary", out_with_canary.get()->data, expected_len, extra_cap + kCanaryBytes);
    Data clean = data_buffer(expected_len);
    std::memcpy(clean.get()->data, out_with_canary.get()->data, expected_len);
    return clean;
}

static void reject_short_decrypt_capacity(sgx_enclave_id_t eid, Key &key, Data &aad, Data &cipher)
{
    if (cipher.get()->datalen <= kAesGcmOverheadBytes)
        throw Failure{};
    uint32_t short_len = (cipher.get()->datalen - kAesGcmOverheadBytes) - 1;
    Data short_out = data_buffer(short_len);
    sgx_status_t result = SGX_ERROR_UNEXPECTED;
    sgx_status_t transport = enclave_decrypt(
        eid, &result, key.get(), key.size(), aad.get(), aad.size(),
        cipher.get(), cipher.size(), short_out.get(), short_out.size());
    expected_invalid_parameter("decrypt short output capacity", transport, result);
}

static void run_compat_and_sm4_matrix(sgx_enclave_id_t eid, Key &aes_key, Data &aad, Data &plain, Data &cipher)
{
    sgx_status_t r = SGX_ERROR_UNEXPECTED;
    // 1. Legacy keybloblen == 0 query on enclave_create_key
    Key query_key(0);
    query_key.get()->metadata.origin = EH_INTERNAL_KEY;
    query_key.get()->metadata.keyspec = EH_AES_GCM_256;
    query_key.get()->metadata.keyusage = EH_KEYUSAGE_ENCRYPT_DECRYPT;
    query_key.get()->keybloblen = 0;
    checked("create_key size query",
            enclave_create_key(eid, &r, query_key.get(), query_key.size()), r);
    if (query_key.get()->keybloblen != kAesGcm256KeyBlobBytes) {
        std::fprintf(stderr, "create_key query keybloblen=%u != %u\n",
                     query_key.get()->keybloblen, kAesGcm256KeyBlobBytes);
        throw Failure{};
    }

    // 2. Legacy datalen == 0 query on enclave_encrypt
    Data enc_query = data_buffer(0);
    checked("encrypt size query",
            enclave_encrypt(eid, &r, aes_key.get(), aes_key.size(), aad.get(), aad.size(),
                            plain.get(), plain.size(), enc_query.get(), enc_query.size()), r);
    if (enc_query.get()->datalen != plain.get()->datalen + kAesGcmOverheadBytes)
        throw Failure{};

    // 3. Legacy datalen == 0 query on enclave_decrypt
    Data dec_query = data_buffer(0);
    checked("decrypt size query",
            enclave_decrypt(eid, &r, aes_key.get(), aes_key.size(), aad.get(), aad.size(),
                            cipher.get(), cipher.size(), dec_query.get(), dec_query.size()), r);
    if (dec_query.get()->datalen != plain.get()->datalen)
        throw Failure{};

    // 4. Short ciphertext (< IV + MAC) rejection on enclave_decrypt
    Data short_cipher = data_buffer(kAesGcmOverheadBytes - 1);
    Data dummy_out = data_buffer(16);
    expected_invalid_parameter(
        "decrypt short ciphertext",
        enclave_decrypt(eid, &r, aes_key.get(), aes_key.size(), aad.get(), aad.size(),
                        short_cipher.get(), short_cipher.size(), dummy_out.get(), dummy_out.size()),
        r);

}

static void run_sm4_producer_consumer_check(sgx_enclave_id_t eid, Data &aad)
{
    sgx_status_t r = SGX_ERROR_UNEXPECTED;
    Key sm4_q(0);
    sm4_q.get()->metadata.origin = EH_INTERNAL_KEY;
    sm4_q.get()->metadata.keyspec = EH_SM4_CTR;
    sm4_q.get()->metadata.keyusage = EH_KEYUSAGE_ENCRYPT_DECRYPT;
    sm4_q.get()->keybloblen = 0;
    checked("sm4 create_key query",
            enclave_create_key(eid, &r, sm4_q.get(), sm4_q.size()), r);
    if (sm4_q.get()->keybloblen == 0)
        throw Failure{};
    Key sm4_key(sm4_q.get()->keybloblen);
    sm4_key.get()->metadata = sm4_q.get()->metadata;
    sm4_key.get()->keybloblen = sm4_q.get()->keybloblen;
    checked("sm4 create_key",
            enclave_create_key(eid, &r, sm4_key.get(), sm4_key.size()), r);

    Data sm4_dk_plain = data_buffer(16);
    Data sm4_dk_cipher_q = data_buffer(0);
    checked("sm4 generate_datakey query",
            enclave_generate_datakey(eid, &r, sm4_key.get(), sm4_key.size(), aad.get(), aad.size(),
                                     sm4_dk_plain.get(), sm4_dk_plain.size(),
                                     sm4_dk_cipher_q.get(), sm4_dk_cipher_q.size()), r);
    Data sm4_dk_cipher = data_buffer(sm4_dk_cipher_q.get()->datalen);
    checked("sm4 generate_datakey",
            enclave_generate_datakey(eid, &r, sm4_key.get(), sm4_key.size(), aad.get(), aad.size(),
                                     sm4_dk_plain.get(), sm4_dk_plain.size(),
                                     sm4_dk_cipher.get(), sm4_dk_cipher.size()), r);
}

static void roundtrip(sgx_enclave_id_t eid, Key &key, Data &aad, size_t bytes)
{
    Data plain = data_buffer(bytes);
    fill_data(plain, static_cast<uint8_t>(bytes));
    Data cipher = encrypt(eid, key, aad, plain);
    Data restored = decrypt(eid, key, aad, cipher);
    require_equal("roundtrip", restored, plain);
}

static void reject_plaintext_length(sgx_enclave_id_t eid, Key &key, Data &aad,
                                    size_t bytes)
{
    Data plain = data_buffer(bytes);
    Data out = data_buffer(1);
    sgx_status_t result = SGX_ERROR_UNEXPECTED;
    sgx_status_t transport = enclave_encrypt(
        eid, &result, key.get(), key.size(), aad.get(), aad.size(),
        plain.get(), plain.size(), out.get(), out.size());
    expected_invalid_parameter("encrypt length", transport, result);
}

struct Options {
    size_t bytes = 32;
    size_t requests = 2;
    std::string domain_key = "domain-key.sealed";
    bool compat_check = false;
    bool sm4_check = false;
    bool help = false;
};

static void usage(const char *program)
{
    std::fprintf(stderr,
                 "usage: %s [--bytes N] [--requests N] [--domain-key PATH]\n",
                 program);
}

static bool parse_size(const char *text, size_t *value)
{
    if (text == nullptr || text[0] < '0' || text[0] > '9')
        return false;
    for (const char *digit = text; *digit != '\0'; digit++)
        if (*digit < '0' || *digit > '9')
            return false;

    char *end = nullptr;
    errno = 0;
    unsigned long long parsed = std::strtoull(text, &end, 10);
    if (errno == ERANGE || end == text || *end != '\0' ||
        parsed > std::numeric_limits<size_t>::max())
        return false;
    *value = static_cast<size_t>(parsed);
    return true;
}

static bool parse_options(int argc, char **argv, Options *options)
{
    for (int i = 1; i < argc; i++) {
        if (std::strcmp(argv[i], "--compat-check") == 0) {
            options->compat_check = true;
            continue;
        }
        if (std::strcmp(argv[i], "--sm4-check") == 0) {
            options->sm4_check = true;
            continue;
        }
        if (std::strcmp(argv[i], "--help") == 0) {
            options->help = true;
            usage(argv[0]);
            return true;
        }
        if (std::strcmp(argv[i], "--domain-key") == 0) {
            if (++i >= argc || argv[i][0] == '\0') {
                usage(argv[0]);
                return false;
            }
            options->domain_key = argv[i];
            continue;
        }

        size_t *destination = nullptr;
        if (std::strcmp(argv[i], "--bytes") == 0)
            destination = &options->bytes;
        else if (std::strcmp(argv[i], "--requests") == 0)
            destination = &options->requests;
        else {
            usage(argv[0]);
            return false;
        }

        if (++i >= argc || !parse_size(argv[i], destination)) {
            usage(argv[0]);
            return false;
        }
    }

    if (options->bytes == 0 || options->bytes > EH_ENCRYPT_MAX_SIZE ||
        options->requests == 0) {
        usage(argv[0]);
        return false;
    }
    return true;
}

static int run(const Options &options)
{
    if (!sgxssl_cpu_profile_supported()) {
        std::fprintf(stderr, "required SGXSSL CPU profile unavailable: %s\n",
                     SGXSSL_CPU_PROFILE_NAME);
        throw Failure{};
    }
    g_domain_key_path = options.domain_key.c_str();

    Data aad = data_buffer(16);
    Data plaintext = data_buffer(options.bytes);
    Data saved_cipher = data_buffer(0);
    Key key(0);

    fill_data(aad, 0x31);
    fill_data(plaintext, 0x53);

    {
        Enclave enclave(ENCLAVE_PATH);
        sgx_status_t result = SGX_ERROR_UNEXPECTED;
        sgx_status_t transport =
            enclave_get_domain_key_from_local(enclave.id(), &result);
        checked("domain key", transport, result);

        key = create_key(enclave.id());
        for (size_t request = 0; request < options.requests; request++) {
            Data cipher = encrypt(enclave.id(), key, aad, plaintext);
            Data restored = decrypt(enclave.id(), key, aad, cipher);
            require_equal("request roundtrip", restored, plaintext);
            if (request + 1 == options.requests)
                saved_cipher = std::move(cipher);
        }

        Data datakey_plain = data_buffer(kAesGcm256KeyBytes);
        Data datakey_cipher = data_buffer(
            datakey_plain.get()->datalen + kAesGcmOverheadBytes);
        transport = enclave_generate_datakey(
            enclave.id(), &result, key.get(), key.size(), aad.get(), aad.size(),
            datakey_plain.get(), datakey_plain.size(), datakey_cipher.get(),
            datakey_cipher.size());
        checked("generate_datakey", transport, result);
        Data datakey_restored =
            decrypt(enclave.id(), key, aad, datakey_cipher);
        require_equal("datakey decrypt", datakey_restored, datakey_plain);

        if (saved_cipher.get()->datalen != 0) {
            uint8_t &mac_byte =
                saved_cipher.get()->data[saved_cipher.get()->datalen - 1];
            mac_byte ^= 0x01;
            Data tampered_plain = data_buffer(options.bytes);
            transport = enclave_decrypt(
                enclave.id(), &result, key.get(), key.size(), aad.get(),
                aad.size(), saved_cipher.get(), saved_cipher.size(),
                tampered_plain.get(), tampered_plain.size());
            rejected("decrypt tampered", transport, result);
            mac_byte ^= 0x01;
            Data restored = decrypt_oversized_capacity(enclave.id(), key, aad, saved_cipher, 64);
            require_equal("restored decrypt", restored, plaintext);
        }

        ehsm_keyusage_t original_usage = key.get()->metadata.keyusage;
        key.get()->metadata.keyusage = EH_KEYUSAGE_SIGN_VERIFY;
        Data rejected_out = data_buffer(1);
        transport = enclave_encrypt(
            enclave.id(), &result, key.get(), key.size(), aad.get(), aad.size(),
            plaintext.get(), plaintext.size(), rejected_out.get(),
            rejected_out.size());
        rejected("encrypt wrong keyusage", transport, result);
        key.get()->metadata.keyusage = original_usage;

        roundtrip(enclave.id(), key, aad, 1);
        roundtrip(enclave.id(), key, aad, EH_ENCRYPT_MAX_SIZE);
        reject_short_decrypt_capacity(enclave.id(), key, aad, saved_cipher);
        reject_plaintext_length(enclave.id(), key, aad,
                                EH_ENCRYPT_MAX_SIZE + 1);
        if (options.compat_check) {
            run_compat_and_sm4_matrix(enclave.id(), key, aad, plaintext, saved_cipher);
        }
        if (options.sm4_check) {
            run_sm4_producer_consumer_check(enclave.id(), aad);
        }

        checked("destroy enclave", enclave.close(), SGX_SUCCESS);
    }

    {
        Enclave enclave(ENCLAVE_PATH);
        sgx_status_t result = SGX_ERROR_UNEXPECTED;
        sgx_status_t transport =
            enclave_get_domain_key_from_local(enclave.id(), &result);
        checked("domain key reload", transport, result);

        Data restored = decrypt(enclave.id(), key, aad, saved_cipher);
        require_equal("saved ciphertext decrypt", restored, plaintext);
        checked("destroy enclave", enclave.close(), SGX_SUCCESS);
    }

    std::puts("eHSM AES-GCM/DataKey functional checks: PASS");
    return 0;
}

int main(int argc, char **argv)
{
    Options options;
    if (!parse_options(argc, argv, &options))
        return 64;
    if (options.help)
        return 0;

    try {
        return run(options);
    } catch (const Failure &) {
        return 1;
    } catch (const std::exception &) {
        std::fprintf(stderr, "host failure\n");
        return 1;
    }
}

extern "C" int ocall_read_domain_key(uint8_t *cipher_dk,
                                     uint32_t cipher_dk_len)
{
    if (cipher_dk == nullptr)
        return -1;

    int fd;
    do {
        fd = open(g_domain_key_path, O_RDONLY | O_CLOEXEC);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0)
        return errno == ENOENT ? -2 : -1;

    size_t offset = 0;
    while (offset < cipher_dk_len) {
        ssize_t got;
        do {
            got = read(fd, cipher_dk + offset, cipher_dk_len - offset);
        } while (got < 0 && errno == EINTR);
        if (got <= 0) {
            close(fd);
            return -1;
        }
        offset += static_cast<size_t>(got);
    }

    uint8_t extra;
    ssize_t more;
    do {
        more = read(fd, &extra, 1);
    } while (more < 0 && errno == EINTR);
    if (close(fd) != 0 || more != 0)
        return -1;
    return 0;
}

static bool write_all(int fd, const uint8_t *data, size_t size)
{
    size_t offset = 0;
    while (offset < size) {
        ssize_t wrote;
        do {
            wrote = write(fd, data + offset, size - offset);
        } while (wrote < 0 && errno == EINTR);
        if (wrote <= 0)
            return false;
        offset += static_cast<size_t>(wrote);
    }
    return true;
}

extern "C" int ocall_store_domain_key(uint8_t *cipher_dk,
                                      uint32_t cipher_dk_len)
{
    if (cipher_dk == nullptr)
        return -1;

    size_t path_len = std::strlen(g_domain_key_path);
    if (path_len > SIZE_MAX - sizeof(".tmp.XXXXXX"))
        return -1;
    char *temporary =
        static_cast<char *>(std::malloc(path_len + sizeof(".tmp.XXXXXX")));
    if (temporary == nullptr)
        return -1;
    std::memcpy(temporary, g_domain_key_path, path_len);
    std::memcpy(temporary + path_len, ".tmp.XXXXXX",
                sizeof(".tmp.XXXXXX"));

    int fd = mkostemp(temporary, O_CLOEXEC);
    if (fd < 0) {
        std::free(temporary);
        return -1;
    }

    bool ok = write_all(fd, cipher_dk, cipher_dk_len);
    if (ok && fsync(fd) != 0)
        ok = false;
    if (close(fd) != 0)
        ok = false;
    if (ok && rename(temporary, g_domain_key_path) != 0)
        ok = false;
    if (!ok) {
        unlink(temporary);
        std::free(temporary);
        return -1;
    }

    std::free(temporary);
    return 0;
}
