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

if [[ $mode == protect ]]; then
  host_runner_mode=${ATFIELD_HOST_RUNNER:-on}
  readiness_backend=${ATFIELD_READINESS_BACKEND:-kernel}
  case $host_runner_mode in
    on|off) ;;
    *) echo "ATFIELD_HOST_RUNNER must be 'on' or 'off'" >&2; exit 64 ;;
  esac
  case $readiness_backend in
    kernel|userspace) ;;
    *) echo "ATFIELD_READINESS_BACKEND must be 'kernel' or 'userspace'" >&2; exit 64 ;;
  esac
  if [[ $host_runner_mode == off && ${ATFIELD_READINESS_BACKEND:-} != userspace ]]; then
    echo "ATFIELD_HOST_RUNNER=off is research-only and requires explicit ATFIELD_READINESS_BACKEND=userspace" >&2
    exit 64
  fi
  export ATFIELD_READINESS_BACKEND="$readiness_backend"
fi

if [[ $group == anchor && ${#run_args[@]} -ne 0 ]]; then
  echo "anchor samples do not accept host arguments" >&2
  exit 64
fi

rm -f "$build_dir/run.json"
sample_enter_shell "$0" "${original_args[@]}"

if [[ $mode == protect ]]; then
  runner_path="$implement_root/host/runner/atfield-run"
  if [[ $host_runner_mode == on ]]; then
    if [[ ! -x $runner_path ]]; then
      echo "protect host runner is missing or not executable: $runner_path" >&2
      exit 66
    fi
    if ! command -v sudo >/dev/null 2>&1; then
      echo "sudo is required to launch protect hosts through atfield-run" >&2
      exit 69
    fi
  else
    echo "RESEARCH ONLY: host CPU lease is bypassed; userspace-readiness is selected explicitly" >&2
  fi
fi

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

runner_ld_library_path=
if [[ $mode == protect && $host_runner_mode == on ]]; then
  runner_ld_library_path=${LD_LIBRARY_PATH:-}
  if [[ -z $runner_ld_library_path ]]; then
    echo "Nix shell LD_LIBRARY_PATH is empty; refusing root protect launch" >&2
    exit 69
  fi
  IFS=: read -r -a runner_ld_dirs <<< "$runner_ld_library_path"
  for library_dir in "${runner_ld_dirs[@]}"; do
    if [[ -z $library_dir || $library_dir != /nix/store/* || ! -d $library_dir ]]; then
      echo "protect runner only accepts existing Nix store library paths in LD_LIBRARY_PATH: $library_dir" >&2
      exit 69
    fi
  done
fi

image_sha_before=$(sha256sum "$build_dir/enclave.signed.so")
image_sha_before=${image_sha_before%% *}
host_sha_before=$(sha256sum "$build_dir/host")
host_sha_before=${host_sha_before%% *}

set +e
if [[ $mode == protect ]]; then
  if [[ $host_runner_mode == on ]]; then
    (cd "$build_dir" && sudo -- "$runner_path" -- /usr/bin/env \
      "LD_LIBRARY_PATH=$runner_ld_library_path" \
      "ATFIELD_READINESS_BACKEND=$readiness_backend" ./host "${run_args[@]}")
  else
    (cd "$build_dir" && ATFIELD_READINESS_BACKEND="$readiness_backend" ./host "${run_args[@]}")
  fi
else
  (cd "$build_dir" && ./host "${run_args[@]}")
fi
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
