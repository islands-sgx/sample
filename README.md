# SGX sample layout

From a bare login shell, prefix a recipe with `nix develop --no-write-lock-file
--command just`. For example:

```sh
nix develop --no-write-lock-file --command just build anchor curve25519-donna raw
nix develop --no-write-lock-file --command just run anchor curve25519-donna raw
nix develop --no-write-lock-file --command just measure-bench
nix develop --no-write-lock-file --command just run bench/micro openssl-aes-256-gcm-1k protect-naive --self-test
nix develop --no-write-lock-file --command just run bench/micro openssl-sha256-4k protect-naive --self-test
nix develop --no-write-lock-file --command just test-sample-cli
nix develop --no-write-lock-file --command just test-anchor-report
nix develop --no-write-lock-file --command just anchor-report build
nix develop --no-write-lock-file --command just anchor-report build --include-bench
```

You can also enter the devShell once with `nix develop --no-write-lock-file`,
then run recipes directly with `just`. If direnv has loaded this devShell,
`just` is available directly there too. The recipes enter the default Nix
shell to provide Bun; `sample.ts` then enters its selected sample shell as usual.

There are four modes. `raw` builds the sample without explicit anchor
preparation. `anchor` prepares the demonstrated anchors. `protect` uses a
frozen v2 workset for the Field boundary; `protect-naive` uses the conservative
workset. Four `anchor` demonstrations are `curve25519-donna`,
`fiat-p384`, `yescrypt`, and `sqlite`. `bench/micro` contains `yescrypt-kdf-rw`,
`wolfssl-pbkdf2-sha256`, `openssl-aes-256-gcm-1k` (encrypt and decrypt),
`openssl-sha256-4k` (hashing), `mlkem-768` (encapsulate and decapsulate), and
`mldsa-65` (sign and verify); `bench/application` contains `ehsm`,
`ehsm-opt-1`, `ehsm-opt-2`, `qe3`, `sgxwallet`, and `signal-cds`. Both bench
scales support all four modes. Anchor demonstrations support `raw` and
`anchor` only.

`just measure-bench` prepares a Profile, acquires a v2 workset, builds all three
benchmark modes, and runs paired trials on every bench sample. It keeps the
normal business path as the main acquisition seed and adds `--self-test` as
supplemental coverage. The report distinguishes application process wall time
from micro ECALL nanoseconds and enclave TSC ticks. A direct `protect` build
uses the frozen v2 workset generated for that sample. An optional
`build/acquire/<group>/<name>/protect/architectural-s3.json` declares known
ENCLU operand-page effects for an exact signed measurement Final. The benchmark
labels these runs `ARCH-DECLARED` only when every raw S3 effect matches the
declaration and was touched in S2 of the same call; the strict S3 verdict
remains `FAIL`, and an extra page still blocks timing.

The OpenSSL AES-GCM sample times encryption and authenticated decryption of
one 1 KiB record with a fresh nonce per round. The SHA-256 sample hashes one
4 KiB message. Both use low-level OpenSSL routines inside the Field and check
a fixed known answer after the timed rounds.

The ML-KEM and ML-DSA samples use pinned source revisions of
[mlkem-native](https://github.com/pq-code-package/mlkem-native) and
[mldsa-native](https://github.com/pq-code-package/mldsa-native). The input
ECALL draws fresh coins with `sgx_read_rand` before each timed round. The
Field uses the caller-supplied-coins APIs, then checks decapsulation or
verification. Their EDL has no OCALL declarations. The samples use the
portable C backends and report cycles for the pair of operations.

The anchor report checks and writes only the four anchor sample pairs by default.
It ignores cached bench runs. Add `--include-bench` to include both bench scales;
every requested raw/anchor run must exist and match its current signed image and
host, or the report fails.

`just run GROUP NAME MODE [host arguments...]` passes trailing arguments to the
sample host. `--self-test` is supported by all micro benchmarks, `ehsm`,
`qe3`, `sgxwallet`, and `signal-cds`. The eHSM variants accept `--bytes N`, `--requests N`, and
`--domain-key PATH`; `ehsm-opt-1` and `ehsm-opt-2` additionally accept
`--compat-check` and `--sm4-check`. Other hosts expose their own help and
options, such as `--key-id` for `qe3`, `--requests` for `sgxwallet`, and
`--records`, `--queries`, `--requests`, `--seed`, or `--in-jids` for
`signal-cds`.

The sample scripts and CMake files select the build mode and assemble each
host and enclave. The host source owns untrusted-side logic. Each sample's
`enclave.edl` defines its trusted call interface; local `enclave.c` or
`enclave.cpp` files implement trusted adapter logic only where needed, while
the eHSM variants and sgxwallet compile their pinned trusted sources.
