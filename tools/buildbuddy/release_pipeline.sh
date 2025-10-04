#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

BAZEL_BINARY="${BAZEL_BINARY:-${REPO_ROOT}/tools/bazel/bazel}"
if [[ ! -x "${BAZEL_BINARY}" ]]; then
    BAZEL_BINARY="bazel"
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

"${BAZEL_BINARY}" run "${BAZEL_FLAGS[@]}" //release:publish_packages -- --tag "${TAG}" "${RELEASE_ARGS[@]}"

echo "Release workflow completed for ${TAG}" >&2
