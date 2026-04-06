#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

maybe_write_remote_rc() {
    local key="${BUILDBUDDY_API_KEY:-${BUILDBUDDY_ORG_API_KEY:-}}"
    local rc_file="${REPO_ROOT}/.bazelrc.remote"

    if [[ -f "${rc_file}" || -z "${key}" ]]; then
        return
    fi

    local old_umask
    old_umask=$(umask)
    umask 077
    printf 'common --remote_header=x-buildbuddy-api-key=%s\n' "${key}" > "${rc_file}"
    umask "${old_umask}"
}

maybe_write_remote_rc

DOCKER_AUTH_SCRIPT="${REPO_ROOT}/buildbuddy_setup_docker_auth.sh"
if [[ -x "${DOCKER_AUTH_SCRIPT}" ]]; then
    "${DOCKER_AUTH_SCRIPT}"
fi

COSIGN_INSTALL_SCRIPT="${REPO_ROOT}/scripts/install-cosign.sh"
if ! command -v cosign >/dev/null 2>&1; then
    if [[ -x "${COSIGN_INSTALL_SCRIPT}" ]]; then
        "${COSIGN_INSTALL_SCRIPT}"
    else
        echo "Cosign is required and installer script is missing: ${COSIGN_INSTALL_SCRIPT}" >&2
        exit 1
    fi
fi

ORAS_INSTALL_SCRIPT="${REPO_ROOT}/scripts/install-oras.sh"
if ! command -v oras >/dev/null 2>&1; then
    if [[ -x "${ORAS_INSTALL_SCRIPT}" ]]; then
        "${ORAS_INSTALL_SCRIPT}"
    else
        echo "ORAS is required and installer script is missing: ${ORAS_INSTALL_SCRIPT}" >&2
        exit 1
    fi
fi

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required environment variable: ${name}" >&2
        exit 1
    fi
}

DEFAULT_BAZEL_WRAPPER="${REPO_ROOT}/tools/bazel/bazel"
BAZEL_BINARY="${BAZEL_BINARY:-${DEFAULT_BAZEL_WRAPPER}}"
if [[ ! -x "${BAZEL_BINARY}" ]]; then
    if command -v "${BAZEL_BINARY}" >/dev/null 2>&1; then
        :
    elif command -v bazelisk >/dev/null 2>&1; then
        BAZEL_BINARY="bazelisk"
    elif command -v bazel >/dev/null 2>&1; then
        BAZEL_BINARY="bazel"
    else
        echo "Neither ${DEFAULT_BAZEL_WRAPPER}, bazelisk, nor bazel is available. Set BAZEL_BINARY to a valid executable." >&2
        exit 1
    fi
fi

BAZEL_FLAGS=()
if [[ "${USE_REMOTE:-1}" != "0" ]]; then
    BAZEL_FLAGS+=("--config=remote")
fi
if [[ "${USE_STAMP:-1}" != "0" ]]; then
    BAZEL_FLAGS+=("--stamp")
fi

# Determine release tag, preferring explicit overrides.
TAG_CANDIDATES=(
    "${RELEASE_TAG:-}"
    "${WORKFLOW_INPUT_tag:-}"
    "${WORKFLOW_TAG:-}"
    "${GIT_TAG:-}"
    "${GITHUB_REF_NAME:-}"
)
TAG=""
for candidate in "${TAG_CANDIDATES[@]}"; do
    if [[ -n "${candidate}" ]]; then
        TAG="${candidate}"
        break
    fi
done
if [[ -z "${TAG}" ]]; then
    if [[ -f "${REPO_ROOT}/VERSION" ]]; then
        TAG="$(<"${REPO_ROOT}/VERSION")"
    elif [[ -n "${GIT_COMMIT:-}" ]]; then
        TAG="sha-${GIT_COMMIT}"
    else
        TAG="sha-dev"
    fi
fi

SANITIZED_TAG="${TAG#v}"
VERSION_FILE="${REPO_ROOT}/VERSION"
if [[ -f "${VERSION_FILE}" ]]; then
    FILE_VERSION="$(<"${VERSION_FILE}")"
    FILE_VERSION="${FILE_VERSION%%[$'\r\n']*}"
    if [[ -n "${FILE_VERSION}" && "${FILE_VERSION}" != "${SANITIZED_TAG}" ]]; then
        if [[ "${ALLOW_VERSION_MISMATCH:-0}" == "1" ]]; then
            echo "Warning: VERSION (${FILE_VERSION}) differs from tag (${SANITIZED_TAG}), continuing due to ALLOW_VERSION_MISMATCH" >&2
        else
            echo "VERSION file (${FILE_VERSION}) does not match release tag (${SANITIZED_TAG}). Update VERSION or set ALLOW_VERSION_MISMATCH=1 to override." >&2
            exit 1
        fi
    fi
fi

declare -a PUSH_ARGS
IFS=' ' read -r -a PUSH_ARGS <<<"${PUSH_EXTRA_ARGS:-}"
if [[ ${#PUSH_ARGS[@]} -eq 1 && -z "${PUSH_ARGS[0]}" ]]; then
    PUSH_ARGS=()
fi

# Prepare release notes arguments if provided.
declare -a RELEASE_ARGS
if [[ -n "${RELEASE_NOTES_FILE:-}" ]]; then
    RELEASE_ARGS+=("--notes_file" "${RELEASE_NOTES_FILE}")
fi
if [[ -n "${RELEASE_NOTES:-}" ]]; then
    RELEASE_ARGS+=("--notes" "${RELEASE_NOTES}")
fi
if [[ "${APPEND_NOTES:-0}" == "1" ]]; then
    RELEASE_ARGS+=("--append_notes")
fi
if [[ "${DRAFT_RELEASE:-0}" == "1" ]]; then
    RELEASE_ARGS+=("--draft")
fi
if [[ "${PRERELEASE:-0}" == "1" ]]; then
    RELEASE_ARGS+=("--prerelease")
fi
if [[ "${OVERWRITE_ASSETS:-}" != "" ]]; then
    RELEASE_ARGS+=("--overwrite_assets=${OVERWRITE_ASSETS}")
fi
if [[ -n "${RELEASE_COMMIT:-}" ]]; then
    RELEASE_ARGS+=("--commit" "${RELEASE_COMMIT}")
fi
if [[ -n "${RELEASE_NAME:-}" ]]; then
    RELEASE_ARGS+=("--name" "${RELEASE_NAME}")
fi
if [[ "${RELEASE_DRY_RUN:-0}" == "1" ]]; then
    RELEASE_ARGS+=("--dry_run")
fi

# Allow passthrough repository override when needed.
if [[ -n "${RELEASE_REPO:-}" ]]; then
    RELEASE_ARGS+=("--repo" "${RELEASE_REPO}")
fi

echo "Publishing release for tag ${TAG}" >&2

if [[ ${#PUSH_ARGS[@]} -eq 1 && -z "${PUSH_ARGS[0]}" ]]; then
    PUSH_ARGS=()
fi
if [[ "${PUSH_DRY_RUN:-0}" == "1" ]]; then
    PUSH_ARGS+=("--dry-run")
fi

"${BAZEL_BINARY}" run "${BAZEL_FLAGS[@]}" //docker/images:push_all -- --tag "${TAG}" "${PUSH_ARGS[@]}"

if [[ "${PUSH_DRY_RUN:-0}" != "1" ]]; then
    SIGN_SCRIPT="${REPO_ROOT}/scripts/sign-oci-publish.sh"
    VERIFY_SCRIPT="${REPO_ROOT}/scripts/verify-oci-publish.sh"
    if [[ ! -x "${SIGN_SCRIPT}" ]]; then
        echo "Publish signing script is missing or not executable: ${SIGN_SCRIPT}" >&2
        exit 1
    fi
    if [[ ! -x "${VERIFY_SCRIPT}" ]]; then
        echo "Publish verification script is missing or not executable: ${VERIFY_SCRIPT}" >&2
        exit 1
    fi

    VERIFY_TAGS=("latest" "${TAG}")
    if git rev-parse HEAD >/dev/null 2>&1; then
        VERIFY_TAGS+=("sha-$(git rev-parse HEAD)")
    elif [[ -n "${GIT_COMMIT:-}" ]]; then
        VERIFY_TAGS+=("sha-${GIT_COMMIT}")
    fi

    declare -A seen_tags=()
    deduped_verify_tags=()
    for verify_tag in "${VERIFY_TAGS[@]}"; do
        if [[ -n "${verify_tag}" && -z "${seen_tags[${verify_tag}]+x}" ]]; then
            deduped_verify_tags+=("${verify_tag}")
            seen_tags["${verify_tag}"]=1
        fi
    done

    "${SIGN_SCRIPT}"
    "${VERIFY_SCRIPT}" "${deduped_verify_tags[@]}"
fi

declare -a WASM_PUSH_ARGS
if [[ "${PUSH_DRY_RUN:-0}" == "1" ]]; then
    WASM_PUSH_ARGS+=("--dry-run")
fi
WASM_PUSH_ARGS+=("--tag" "${TAG}")

if [[ "${PUSH_DRY_RUN:-0}" != "1" ]]; then
    require_env "PLUGIN_UPLOAD_SIGNING_PRIVATE_KEY"
    require_env "PLUGIN_UPLOAD_SIGNING_KEY_ID"
fi

"${REPO_ROOT}/scripts/push_all_wasm_plugins.sh" "${WASM_PUSH_ARGS[@]}"

if [[ "${PUSH_DRY_RUN:-0}" != "1" ]]; then
    WASM_SIGN_SCRIPT="${REPO_ROOT}/scripts/sign-wasm-plugin-publish.sh"
    WASM_VERIFY_SCRIPT="${REPO_ROOT}/scripts/verify-wasm-plugin-publish.sh"
    if [[ ! -x "${WASM_SIGN_SCRIPT}" ]]; then
        echo "Wasm signing script is missing or not executable: ${WASM_SIGN_SCRIPT}" >&2
        exit 1
    fi
    if [[ ! -x "${WASM_VERIFY_SCRIPT}" ]]; then
        echo "Wasm verification script is missing or not executable: ${WASM_VERIFY_SCRIPT}" >&2
        exit 1
    fi

    WASM_VERIFY_TAGS=("${TAG}")
    if git rev-parse HEAD >/dev/null 2>&1; then
        WASM_VERIFY_TAGS=("sha-$(git rev-parse HEAD)" "${TAG}")
    elif [[ -n "${GIT_COMMIT:-}" ]]; then
        WASM_VERIFY_TAGS=("sha-${GIT_COMMIT}" "${TAG}")
    fi

    declare -A seen_wasm_tags=()
    deduped_wasm_verify_tags=()
    for verify_tag in "${WASM_VERIFY_TAGS[@]}"; do
        if [[ -n "${verify_tag}" && -z "${seen_wasm_tags[${verify_tag}]+x}" ]]; then
            deduped_wasm_verify_tags+=("${verify_tag}")
            seen_wasm_tags["${verify_tag}"]=1
        fi
    done

    "${WASM_SIGN_SCRIPT}" "${deduped_wasm_verify_tags[@]}"
    "${WASM_VERIFY_SCRIPT}" "${deduped_wasm_verify_tags[@]}"
fi

"${BAZEL_BINARY}" run "${BAZEL_FLAGS[@]}" //build/release:publish_packages -- --tag "${TAG}" "${RELEASE_ARGS[@]}"

echo "Release workflow completed for ${TAG}" >&2
