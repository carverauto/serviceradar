#!/usr/bin/env bash
set -euo pipefail

# BuildBuddy Enterprise Cache Proxy deployment.
#
# This is a script rather than a Bazel target for the one permitted reason: it reads a
# credential (the BuildBuddy API key) out of a Kubernetes secret and passes it to Helm. Making
# that a Bazel action would turn the key into an action input. Everything else here is a
# single `helm upgrade`; do not grow this file beyond the credential handling.
#
# Portable bash: no `mapfile`, no `declare -A`, no bash 4 syntax -- macOS ships bash 3.2.

NAMESPACE="buildbuddy"
# Keep this SHORT. The chart derives a headless Service named
# "<release>-buildbuddy-enterprise-cache-proxy-headless", and a Service name may not exceed 63
# characters. The chart contributes 33 + the "-headless" suffix contributes 9 + 1 separator,
# leaving exactly 20 for the release name. "buildbuddy-cache-proxy" is 22 and produced a
# release that failed with `metadata.name: Invalid value: ... must be no more than 63
# characters` -- helm created the ServiceAccount, Role, PDB and Secret, then aborted before the
# StatefulSet, so the release looked half-installed.
RELEASE_NAME="bb-cache-proxy"
# A DIFFERENT secret from the executors' buildbuddy-api-key, because it needs a different
# capability. A cache proxy registers with the app over a long-lived stream, which requires an
# API key carrying REGISTER_CACHE_PROXY; an executor key does not have it. Sharing the executor
# key deploys a proxy that serves cache traffic perfectly well but loops every 30s on
#     PermissionDenied: API key is missing REGISTER_CACHE_PROXY capability
# and never appears on the app's Cache Proxies page, so its hit rate is invisible.
#
# Deliberately NOT falling back to buildbuddy-api-key when this is absent: the fallback works
# well enough to look fine while silently costing the observability this exists to provide.
SECRET_NAME="buildbuddy-cache-proxy-key"
CHART="buildbuddy/buildbuddy-enterprise-cache-proxy"
CHART_VERSION="0.0.31"
CHART_REPO_NAME="buildbuddy"
CHART_REPO_URL="https://helm.buildbuddy.io"
VALUES_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/values-cache.yaml"

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run=true
fi

# Fail fast and locally rather than half-installing a release, as happened once already.
MAX_RELEASE_NAME_LEN=20
if [[ "${#RELEASE_NAME}" -gt "${MAX_RELEASE_NAME_LEN}" ]]; then
    echo "error: RELEASE_NAME '${RELEASE_NAME}' is ${#RELEASE_NAME} chars; max is ${MAX_RELEASE_NAME_LEN}" >&2
    echo "       the chart's headless Service name would exceed Kubernetes' 63-char limit" >&2
    exit 1
fi

# A separate release from the executor's `buildbuddy`. They are different charts with
# different lifecycles; sharing a release name would make `helm upgrade` of one delete the
# other's resources.
if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "${CHART_REPO_NAME}"; then
    echo "Adding Helm repo '${CHART_REPO_NAME}' (${CHART_REPO_URL})"
    helm repo add "${CHART_REPO_NAME}" "${CHART_REPO_URL}"
fi

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "error: namespace '${NAMESPACE}' not found -- is KUBECONFIG pointing at the right cluster?" >&2
    echo "       the executor fleet lives there, so this should already exist" >&2
    exit 1
fi

if ! kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "error: secret '${SECRET_NAME}' not found in namespace '${NAMESPACE}'" >&2
    echo >&2
    echo "This needs a cache-proxy API key, NOT the executor key in buildbuddy-api-key." >&2
    echo "Create one in BuildBuddy under Settings -> Org API keys with the cache-proxy" >&2
    echo "capability, then:" >&2
    echo >&2
    echo "  kubectl create secret generic ${SECRET_NAME} -n ${NAMESPACE} \\" >&2
    echo "    --from-literal=api-key='YOUR_CACHE_PROXY_API_KEY'" >&2
    exit 1
fi

API_KEY="$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.data.api-key}' | base64 -d)"

if [[ -z "${API_KEY}" ]]; then
    echo "error: api-key is empty in secret ${SECRET_NAME}" >&2
    exit 1
fi

if [[ ! -f "${VALUES_FILE}" ]]; then
    echo "error: values file not found: ${VALUES_FILE}" >&2
    exit 1
fi

# --version is pinned deliberately. `helm upgrade` without it silently adopts whatever is
# newest in the local repo index, which turns a config change into an unreviewed chart bump.
helm_args=(
    upgrade "${RELEASE_NAME}" "${CHART}"
    --install
    --namespace "${NAMESPACE}"
    --version "${CHART_VERSION}"
    -f "${VALUES_FILE}"
    --set-string "config.cache_proxy.api_key=${API_KEY}"
)

if [[ "${dry_run}" == true ]]; then
    echo "==> DRY RUN (rendering only, nothing applied)"
    helm "${helm_args[@]}" --dry-run
    exit 0
fi

echo "==> Deploying ${RELEASE_NAME} (chart ${CHART} ${CHART_VERSION}) to namespace ${NAMESPACE}"
helm "${helm_args[@]}"

STS="${RELEASE_NAME}-buildbuddy-enterprise-cache-proxy"

echo
echo "Deployment submitted. Watch it come up with:"
echo "  kubectl rollout status statefulset/${STS} -n ${NAMESPACE} --timeout=10m"
echo "  kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/instance=${RELEASE_NAME} -o wide"
echo
echo "Confirm it reads through to OUR instance and not BuildBuddy's shared cloud:"
echo "  kubectl get secret -n ${NAMESPACE} ${STS}-config -o jsonpath='{.data.config\\.yaml}' \\"
echo "    | base64 -d | grep -A2 cache_proxy"
echo "  (must show carverauto.buildbuddy.io, NOT remote.buildbuddy.io)"
echo
echo "Nothing points at the proxy yet. Once the pods are healthy, route traffic to it:"
echo "  1. executors: set config.executor.cache_target in values.yaml, then ./deploy.sh"
echo "  2. clients:   --remote_cache=grpcs://<proxy-svc>:1985 in //.bazelrc, and"
echo "                --remote_bytestream_uri_prefix=grpcs://carverauto.buildbuddy.io so BES"
echo "                artifact links still resolve. Leave --remote_executor alone."
