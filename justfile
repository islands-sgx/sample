set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments

default:
    @just --list

build group name mode:
    @bun scripts/sample.ts build {{quote(group)}} {{quote(name)}} {{quote(mode)}}

run group name mode *args:
    @bun scripts/sample.ts run "$1" "$2" "$3" "${@:4}"

test-sample-cli:
    @bun test scripts/sample-cli.test.ts

anchor-all:
    @just run anchor curve25519-donna raw
    @just run anchor curve25519-donna anchor
    @just run anchor fiat-p384 raw
    @just run anchor fiat-p384 anchor
    @just run anchor yescrypt raw
    @just run anchor yescrypt anchor
    @just run anchor sqlite raw
    @just run anchor sqlite anchor
    @bun scripts/anchor-report.ts build
