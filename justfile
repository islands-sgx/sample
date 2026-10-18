set shell := ["bash", "-eu", "-o", "pipefail", "-c"]
set positional-arguments

default:
    @just --list

build group name mode:
    @bash scripts/build-sample.sh {{quote(group)}} {{quote(name)}} {{quote(mode)}}

run group name mode *args:
    @bash scripts/run-sample.sh "$1" "$2" "$3" "${@:4}"

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
