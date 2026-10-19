sample_setup() {
  group=$1
  name=$2
  mode=$3

  case $group in
    anchor|real) ;;
    *) echo "GROUP must be anchor or real" >&2; return 64 ;;
  esac
  case $mode in
    raw|anchor|protect) ;;
    *) echo "MODE must be raw, anchor, or protect" >&2; return 64 ;;
  esac
  if [[ $group == anchor && $mode == protect ]]; then
    echo "anchor demonstrations have no Field or protect mode" >&2
    return 64
  fi
  if [[ ! $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "NAME must use lower-case words separated by hyphens" >&2
    return 64
  fi

  project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  source_root="$project_root/$group/$name"
  build_dir="$project_root/build/$group/$name/$mode"
  sample_shell="$group-$name-$mode"
  sample_marker="$group/$name/$mode"
  if [[ $mode == protect ]]; then
    implement_root=${ATFIELD_IMPLEMENT_ROOT:-$project_root/../implement}
    if [[ ! -d $implement_root ]]; then
      echo "implement repository is missing: $implement_root" >&2
      return 66
    fi
    implement_root=$(cd "$implement_root" && pwd)
  fi

  if [[ ! -f "$source_root/CMakeLists.txt" ]]; then
    echo "unknown $group sample: $name" >&2
    return 64
  fi
}

sample_enter_shell() {
  if [[ ${ATFIELD_SAMPLE_SHELL:-} == "$sample_marker" ]]; then
    return 0
  fi
  shell_env=("ATFIELD_SAMPLE_SHELL=$sample_marker")
  if [[ $mode == protect ]]; then
    shell_env+=("ATFIELD_IMPLEMENT_ROOT=$implement_root")
  fi
  exec nix develop --no-write-lock-file "$project_root#$sample_shell" \
    --command env "${shell_env[@]}" bash "$@"
}
