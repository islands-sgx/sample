set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments

default:
    @just --list

build group name mode:
    @nix develop --no-write-lock-file --command bun scripts/sample.ts build {{quote(group)}} {{quote(name)}} {{quote(mode)}}

profile group name:
    @nix develop --no-write-lock-file --command bun scripts/sample.ts profile {{quote(group)}} {{quote(name)}} protect

run-built group name mode *args:
    @nix develop --no-write-lock-file --command bun scripts/sample.ts run-built "$1" "$2" "$3" "${@:4}"

run group name mode *args:
    @nix develop --no-write-lock-file --command bun scripts/sample.ts run "$1" "$2" "$3" "${@:4}"

test-sample-cli:
    @nix develop --no-write-lock-file --command bun test scripts/sample-cli.test.ts

test-anchor-report:
    @nix develop --no-write-lock-file --command bun test scripts/anchor-report.test.ts

anchor-report *args:
    @nix develop --no-write-lock-file --command bun scripts/anchor-report.ts "${@:1}"

measure-bench *args:
    @nix develop --no-write-lock-file --command bun scripts/measure-bench.ts "${@:1}"

anchor-all:
    @just run anchor curve25519-donna raw
    @just run anchor curve25519-donna anchor
    @just run anchor fiat-p384 raw
    @just run anchor fiat-p384 anchor
    @just run anchor yescrypt raw
    @just run anchor yescrypt anchor
    @just run anchor sqlite raw
    @just run anchor sqlite anchor
    @just anchor-report build
