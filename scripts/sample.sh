sample_setup() {
  group=$1
  name=$2
  mode=$3

  case $group in
    anchor|real) ;;
    *) echo "GROUP must be anchor or real" >&2; return 64 ;;
  esac
  case $mode in
    raw|anchor) ;;
    *) echo "MODE must be raw or anchor" >&2; return 64 ;;
  esac
  if [[ ! $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "NAME must use lower-case words separated by hyphens" >&2
    return 64
  fi

  project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  source_root="$project_root/$group/$name"
  build_dir="$project_root/build/$group/$name/$mode"
  sample_shell="$group-$name-$mode"
  sample_marker="$group/$name/$mode"

  if [[ ! -f "$source_root/CMakeLists.txt" ]]; then
    echo "unknown $group sample: $name" >&2
    return 64
  fi
}

sample_enter_shell() {
  if [[ ${ATFIELD_SAMPLE_SHELL:-} == "$sample_marker" ]]; then
    return 0
  fi
  exec nix develop --no-write-lock-file "$project_root#$sample_shell" \
    --command env "ATFIELD_SAMPLE_SHELL=$sample_marker" bash "$@"
}
