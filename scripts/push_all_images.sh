#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAZEL_BIN="${BAZEL_BIN:-bazel}"
# Default to --config=remote, not --config=ci. This script is only reached from
# `make push_all` on Darwin (the Linux branch runs //:push with $BAZEL_CI_FLAGS,
# which is already `-c opt --config=remote`), and the ci profile points its caches
# at /bazel-cache -- a node volume only the BuildBuddy executors mount. On a
# workstation that fails before any image is pushed:
#   ERROR: [unix_jni.cc:471] /bazel-cache (Read-only file system)
#   ERROR: could not acquire lock on repo contents cache
BAZEL_CONFIG="${BAZEL_CONFIG:-remote}"
BAZEL_QUERY='attr(name, ".*_push$", //docker/images:*)'
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

extra_tag=""
dry_run=false
passthrough_args=()
bazel_bin_dir=""
darwin_crane=""
darwin_jq=""
patched_scripts=()

# EXIT, not RETURN. The previous `trap cleanup RETURN` sat at top level inside the target
# loop, and a RETURN trap only fires when a shell function or a sourced script returns -- so
# it never ran, and any push that failed left its temp file behind. EXIT is POSIX and fires
# on both a normal exit and a `set -e` abort.
cleanup_patched_scripts() {
  if [[ ${#patched_scripts[@]} -gt 0 ]]; then
    rm -f "${patched_scripts[@]}"
  fi
}
trap cleanup_patched_scripts EXIT

# `bazel info bazel-bin` is configuration-dependent: a config that sets
# `--compilation_mode=opt` reports a different output path than a bare `info`
# does. Resolving it without the config the build actually uses pointed this
# script at the fastbuild tree, which does not exist, and it died with
# "unable to resolve bazel-bin" before pushing anything.
resolve_bazel_info_path() {
  local key="$1"
  local output

  if ! output="$("${BAZEL_BIN}" info "--config=${BAZEL_CONFIG}" "${key}" 2>&1)"; then
    printf '%s\n' "${output}" >&2
    echo "error: unable to resolve bazel info ${key}" >&2
    exit 1
  fi

  printf '%s\n' "${output}" | awk '/^\// { path = $0 } END { print path }'
}

usage() {
  cat <<'EOF'
Usage: ./scripts/push_all_images.sh [--tag <tag>] [--dry-run] [-- <oci_push args>...]

Push all publishable OCI images by running each Bazel `*_push` target sequentially.
This avoids the `rules_multirun` aggregate launcher, which is not reliable on macOS
when remote execution resolves host tools for Linux.

Options:
  --tag <tag>   Add an extra runtime tag to every image push.
  --dry-run     Print the Bazel commands without executing them.
  --help        Show this help.

Environment:
  BAZEL_BIN     Bazel executable to use (default: bazel)
  BAZEL_CONFIG  Bazel config to use for runs (default: remote)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || { echo "error: --tag requires a value" >&2; exit 1; }
      extra_tag="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      passthrough_args+=("$@")
      break
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "${REPO_ROOT}"

bazel_bin_dir="$(resolve_bazel_info_path bazel-bin)"

if [[ -z "${bazel_bin_dir}" || ! -d "${bazel_bin_dir}" ]]; then
  echo "error: unable to resolve bazel-bin" >&2
  exit 1
fi

resolve_darwin_tools() {
  [[ "${HOST_OS}" == "Darwin" ]] || return 0
  [[ -n "${darwin_crane}" && -n "${darwin_jq}" ]] && return 0

  local repo_suffix
  case "${HOST_ARCH}" in
    arm64|aarch64)
      repo_suffix="darwin_arm64"
      ;;
    x86_64|amd64)
      repo_suffix="darwin_amd64"
      ;;
    *)
      echo "error: unsupported macOS architecture: ${HOST_ARCH}" >&2
      exit 1
      ;;
  esac

  "${BAZEL_BIN}" build \
    "@@rules_oci++oci+oci_crane_${repo_suffix}//:crane" \
    "@@aspect_bazel_lib++toolchains+jq_${repo_suffix}//:jq" >/dev/null

  local output_base
  output_base="$(resolve_bazel_info_path output_base)"

  darwin_crane="${output_base}/external/rules_oci++oci+oci_crane_${repo_suffix}/crane"
  darwin_jq="${output_base}/external/aspect_bazel_lib++toolchains+jq_${repo_suffix}/jq"

  if [[ ! -x "${darwin_crane}" || ! -x "${darwin_jq}" ]]; then
    echo "error: failed to resolve Darwin crane/jq binaries" >&2
    exit 1
  fi
}

# `mapfile` is a bash 4.0 builtin and macOS ships bash 3.2, where it does not exist
# ("mapfile: command not found"). This read loop is the portable stand-in.
push_targets=()
while IFS= read -r push_target; do
  push_targets+=("${push_target}")
done < <(
  "${BAZEL_BIN}" query "${BAZEL_QUERY}" 2>/dev/null |
    grep '^//docker/images:' |
    LC_ALL=C sort
)

if [[ ${#push_targets[@]} -eq 0 ]]; then
  echo "error: no Bazel image push targets found" >&2
  exit 1
fi

for target in "${push_targets[@]}"; do
  if [[ "${HOST_OS}" == "Darwin" ]]; then
    resolve_darwin_tools

    target_name="${target##*:}"
    # --remote_download_outputs is required on THIS branch and only this branch.
    # //.bazelrc's remote_base sets --remote_download_minimal, so a plain build leaves outputs
    # in the CAS -- but this path never `bazel run`s the target. It reads the generated
    # launcher and the image layout off local disk, so both have to be materialised. Without
    # it you get "missing generated push launcher", and past that ${IMAGE_DIR}/index.json is
    # absent and crane has nothing to push.
    #
    # `toplevel`, NOT `all`. `all` materialises every output of every action in the graph --
    # thousands of intermediate artifacts dragged across the WAN to publish one image.
    # `toplevel` fetches only the requested target's own outputs and runfiles, which is
    # exactly the launcher plus the OCI layout. Verified: blobs/, index.json and oci-layout
    # are all present under the launcher's .runfiles with `toplevel`.
    #
    # The Linux branch below needs none of this: `bazel run` materialises its own runfiles.
    build_cmd=("${BAZEL_BIN}" build "--config=${BAZEL_CONFIG}" --remote_download_outputs=toplevel --stamp "${target}")
    script_path="${bazel_bin_dir}/docker/images/push_${target_name}.sh"
    args=()

    if [[ -n "${extra_tag}" ]]; then
      args+=(--tag "${extra_tag}")
    fi
    if [[ ${#passthrough_args[@]} -gt 0 ]]; then
      args+=("${passthrough_args[@]}")
    fi

    printf '==> %s\n' "${target}"
    printf '    '
    printf '%q ' "${build_cmd[@]}"
    printf '\n'

    if [[ "${dry_run}" == true ]]; then
      printf '    patch CRANE=%q JQ=%q in %q and execute from %q\n' "${darwin_crane}" "${darwin_jq}" "${script_path}" "${bazel_bin_dir}"
      continue
    fi

    "${build_cmd[@]}"

    if [[ ! -f "${script_path}" ]]; then
      echo "error: missing generated push launcher: ${script_path}" >&2
      exit 1
    fi

    patched_script="$(mktemp "${TMPDIR:-/tmp}/push.${target_name}.darwin.XXXXXX")"
    patched_scripts+=("${patched_script}")
    # sed rather than `perl -0pi`: these are line-oriented substitutions that POSIX sed does
    # natively, and it drops a perl dependency that is absent from FreeBSD's base system and
    # from minimal Linux images. Deliberately NOT `sed -i` -- GNU and BSD sed disagree on how
    # its backup suffix is spelled, so we write to the temp file instead. `|` is the delimiter
    # because both replacements are absolute paths.
    sed \
      -e "s|^readonly CRANE=.*|readonly CRANE=\"${darwin_crane}\"|" \
      -e "s|^readonly JQ=.*|readonly JQ=\"${darwin_jq}\"|" \
      "${script_path}" > "${patched_script}"
    chmod +x "${patched_script}"

    (
      cd "${bazel_bin_dir}"
      # RUNFILES_DIR has to be passed explicitly. The launcher locates its runfiles from $0,
      # and $0 here is the patched copy in TMPDIR, which has no .runfiles tree beside it -- so
      # the copy died in runfiles.bash init ("cannot find
      # bazel_tools/tools/bash/runfiles/runfiles.bash") before reaching any push logic. The
      # original launcher's tree next to script_path is the one that actually has the image
      # layout, so point at that.
      #
      # `${args[@]+"${args[@]}"}`, not `"${args[@]}"`: bash before 4.4 -- and macOS ships
      # 3.2 -- treats an empty array expansion as an unbound variable under `set -u`, so a
      # push with neither --tag nor passthrough args aborted right here. This is the same
      # idiom rules_oci uses in the launcher being patched.
      RUNFILES_DIR="${script_path}.runfiles" \
        "${patched_script}" ${args[@]+"${args[@]}"}
    )
  else
    cmd=("${BAZEL_BIN}" run "--config=${BAZEL_CONFIG}" --stamp "${target}")

    if [[ -n "${extra_tag}" || ${#passthrough_args[@]} -gt 0 ]]; then
      cmd+=(--)
      if [[ -n "${extra_tag}" ]]; then
        cmd+=(--tag "${extra_tag}")
      fi
      if [[ ${#passthrough_args[@]} -gt 0 ]]; then
        cmd+=("${passthrough_args[@]}")
      fi
    fi

    printf '==> %s\n' "${target}"
    printf '    '
    printf '%q ' "${cmd[@]}"
    printf '\n'

    if [[ "${dry_run}" == false ]]; then
      "${cmd[@]}"
    fi
  fi
done
