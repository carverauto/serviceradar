#!/usr/bin/env bash
#
# Deploys Dgraph to the `ci` or `demo` environment, or re-mirrors the images into Harbor.
#
# A SCRIPT RATHER THAN A BAZEL TARGET, deliberately, and the same exception //k8s/buildbuddy
# already takes: this drives a live cluster and a registry with ambient credentials. Those are
# not build inputs, there is nothing to cache, and a Bazel action that mutates a cluster is a
# hole in the graph rather than a member of it. Nothing here builds an artifact.
#
#   ./deploy-dgraph.sh ci        # 1 Zero, 1 Alpha, disposable fixture
#   ./deploy-dgraph.sh demo      # 3 Zeros, 3 Alphas, replication 3, public TLS
#   ./deploy-dgraph.sh mirror    # copy the pinned images into Harbor
set -euo pipefail

CHART_REPO_NAME="dgraph"
CHART_REPO_URL="https://charts.dgraph.io"
RELEASE_NAME="dgraph"
HARBOR="registry.carverauto.dev"
# Keep in step with `image.tag` in ci/values.yaml and demo/values.yaml. The mirror target and
# the deployed tag drifting apart is the failure this constant exists to prevent.
DGRAPH_TAG="v25.4.0"
# The newest STABLE chart. 25.0.0-preview6 exists but is a preview, and its appVersion is
# v25.0.0-preview6 rather than a release. Pinned so a new chart publication cannot turn a
# values-only change into a chart upgrade.
CHART_VERSION="24.1.4"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '3,12p' "${BASH_SOURCE[0]}" >&2; exit 2; }

mirror_images() {
  command -v crane >/dev/null || { echo "error: crane is required to mirror" >&2; exit 1; }
  for tag in "${DGRAPH_TAG}" "${DGRAPH_TAG}-amd64" "${DGRAPH_TAG}-arm64"; do
    echo "mirroring dgraph/dgraph:${tag}"
    crane cp "docker.io/dgraph/dgraph:${tag}" "${HARBOR}/mirror/dgraph/dgraph:${tag}"
  done
}

deploy() {
  local env="$1" namespace="$2"
  local values="${here}/${env}/values.yaml"
  [[ -f "$values" ]] || { echo "error: no values file at ${values}" >&2; exit 1; }

  # Resolves against a locally configured Helm repo; without this the install fails with
  # "repo dgraph not found" rather than anything about Dgraph.
  if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "$CHART_REPO_NAME"; then
    helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL"
  fi
  helm repo update "$CHART_REPO_NAME" >/dev/null

  kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace"

  # demo terminates TLS with a real certificate, so the Certificate has to exist before Alpha
  # starts. Applied first and waited on: an Alpha that starts without node.crt does not fail,
  # it serves plaintext, which is the one outcome no caller would notice.
  # Both environments terminate TLS with a cert-manager certificate, and the chart mounts that
  # secret unconditionally -- so it has to exist before Alpha starts, or the pod sits in
  # ContainerCreating on a missing secret.
  kubectl apply -n "$namespace" -f "${here}/${env}/certificate.yaml"
  echo "waiting for certificate dgraph-alpha-tls to be issued..."
  kubectl wait --for=condition=Ready --timeout=300s \
    -n "$namespace" certificate/dgraph-alpha-tls

  helm upgrade --install "$RELEASE_NAME" "${CHART_REPO_NAME}/dgraph" \
    --version "$CHART_VERSION" \
    -n "$namespace" \
    -f "$values" \
    --wait --timeout 15m

  echo
  echo "deployed. check with:"
  echo "  kubectl get pods -n ${namespace} -l app.kubernetes.io/name=dgraph"
  echo "  kubectl exec -n ${namespace} ${RELEASE_NAME}-dgraph-alpha-0 -- dgraph version"
}

case "${1:-}" in
  ci)     deploy ci   dgraph-ci ;;
  demo)   deploy demo dgraph ;;
  mirror) mirror_images ;;
  *)      usage ;;
esac
