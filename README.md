# SGX sample layout

From a bare login shell, prefix a recipe with `nix develop --no-write-lock-file
--command just`. For example:

```sh
nix develop --no-write-lock-file --command just build anchor curve25519-donna raw
nix develop --no-write-lock-file --command just run anchor curve25519-donna raw
nix develop --no-write-lock-file --command just build real ehsm protect
nix develop --no-write-lock-file --command just run real ehsm protect --self-test
nix develop --no-write-lock-file --command just test-sample-cli
nix develop --no-write-lock-file --command just test-anchor-report
nix develop --no-write-lock-file --command just anchor-report build
nix develop --no-write-lock-file --command just anchor-report build --include-real
```

You can also enter the devShell once with `nix develop --no-write-lock-file`,
then run recipes directly with `just`. If direnv has loaded this devShell,
`just` is available directly there too. The recipes enter the default Nix
shell to provide Bun; `sample.ts` then enters its selected sample shell as usual.

There are three modes. `raw` builds the sample without explicit anchor
preparation. `anchor` prepares the demonstrated anchors. `protect` is for real
samples and enables the Field boundary. Four anchor demonstrations are
`curve25519-donna`, `fiat-p384`, `yescrypt`, and `sqlite`; six real samples are
`ehsm`, `ehsm-opt-1`, `ehsm-opt-2`, `qe3`, `sgxwallet`, and `signal-cds`.
Anchor samples have `raw` and `anchor` modes; real samples also have `protect`.

The anchor report checks and writes only the four anchor sample pairs. It ignores cached real runs. Add `--include-real` to include the real sample report; every requested raw/anchor run must exist and match its current signed image and host, or the report fails.

`just run GROUP NAME MODE [host arguments...]` passes trailing arguments to the
sample host. `--self-test` is supported by `ehsm`, `qe3`, `sgxwallet`, and
`signal-cds`. The eHSM variants accept `--bytes N`, `--requests N`, and
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
