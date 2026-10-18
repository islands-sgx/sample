#!/usr/bin/env bash
set -euo pipefail

if (($# < 3)); then
  echo "usage: run-sample.sh GROUP NAME MODE [host args...]" >&2
  exit 64
fi

source "$(dirname "$0")/sample.sh"
sample_setup "$1" "$2" "$3"
original_args=("$@")
group=$1
name=$2
mode=$3
shift 3
run_args=("$@")

if [[ $group == anchor && ${#run_args[@]} -ne 0 ]]; then
  echo "anchor samples do not accept host arguments" >&2
  exit 64
fi

rm -f "$build_dir/run.json"
sample_enter_shell "$0" "${original_args[@]}"

bash "$project_root/scripts/build-sample.sh" "$group" "$name" "$mode"

if [[ ${SGX_MODE:-} != HW ]]; then
  echo "SGX_MODE must be HW; simulation fallback is disabled" >&2
  exit 69
fi
device=/dev/sgx_enclave
if [[ -e /dev/sgx/enclave ]]; then
  device=/dev/sgx/enclave
fi
if [[ ! -e $device || ! -r $device || ! -w $device ]]; then
  echo "SGX hardware device is unavailable or not accessible: $device" >&2
  exit 69
fi
if [[ ! -x "$build_dir/host" || ! -f "$build_dir/enclave.signed.so" ]]; then
  echo "build output is incomplete: $build_dir" >&2
  exit 66
fi

image_sha_before=$(sha256sum "$build_dir/enclave.signed.so")
image_sha_before=${image_sha_before%% *}
host_sha_before=$(sha256sum "$build_dir/host")
host_sha_before=${host_sha_before%% *}

set +e
(cd "$build_dir" && ./host "${run_args[@]}")
exit_code=$?
set -e
if ((exit_code != 0)); then
  exit "$exit_code"
fi

image_sha_after=$(sha256sum "$build_dir/enclave.signed.so")
image_sha_after=${image_sha_after%% *}
host_sha_after=$(sha256sum "$build_dir/host")
host_sha_after=${host_sha_after%% *}
if [[ $image_sha_before != "$image_sha_after" || $host_sha_before != "$host_sha_after" ]]; then
  echo "build outputs changed during the hardware run" >&2
  exit 75
fi

temporary="$build_dir/.run.json.$$"
trap 'rm -f "$temporary"' EXIT
printf '{"exitCode":0,"imageSha256":"%s","hostSha256":"%s"}\n' \
  "$image_sha_before" "$host_sha_before" > "$temporary"
mv "$temporary" "$build_dir/run.json"
