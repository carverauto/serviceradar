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

# The HMAC secret Dgraph signs ACL tokens with.
#
# GENERATED HERE RATHER THAN COMMITTED, and this is the credential-handling exception this
# script exists under: an HMAC key in values.yaml is a key in the repository, and a Bazel action
# that mints one would make the secret a build input. The chart mounts
# <release>-dgraph-alpha-acl-secret whenever alpha.acl.enabled is true, while templating it only
# when alpha.acl.file is non-empty -- so leaving that empty hands ownership here, exactly as
# alpha.tls.files hands the TLS secret to cert-manager.
#
# Created once and then left alone: rotating it invalidates every issued token, so a blind
# recreate on every deploy would log every client out mid-run.
ensure_acl_secret() {
  local namespace="$1" name="dgraph-dgraph-alpha-acl-secret"

  if kubectl get secret "$name" -n "$namespace" >/dev/null 2>&1; then
    echo "acl secret ${name} already exists; leaving it alone"
    return 0
  fi

  # Dgraph wants at least 256 bits; 48 alphanumerics is comfortably past that.
  echo "creating acl secret ${name}"
  kubectl create secret generic "$name" -n "$namespace" \
    --from-literal=hmac_secret_file="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48)"
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

  # Declared, not created imperatively, where a manifest exists: the namespace carries a Pod
  # Security level, and `kubectl create namespace` would silently give it the cluster default.
  if [[ -f "${here}/${env}/namespace.yaml" ]]; then
    kubectl apply -f "${here}/${env}/namespace.yaml"
  else
    kubectl get namespace "$namespace" >/dev/null 2>&1 || kubectl create namespace "$namespace"
  fi

  # demo terminates TLS with a real certificate, so the Certificate has to exist before Alpha
  # starts. Applied first and waited on: an Alpha that starts without node.crt does not fail,
  # it serves plaintext, which is the one outcome no caller would notice.
  # Both environments terminate TLS with a cert-manager certificate, and the chart mounts that
  # secret unconditionally -- so it has to exist before Alpha starts, or the pod sits in
  # ContainerCreating on a missing secret.
  ensure_acl_secret "$namespace"

  kubectl apply -n "$namespace" -f "${here}/${env}/certificate.yaml"
  echo "waiting for certificate dgraph-alpha-tls to be issued..."
  kubectl wait --for=condition=Ready --timeout=300s \
    -n "$namespace" certificate/dgraph-alpha-tls

  helm upgrade --install "$RELEASE_NAME" "${CHART_REPO_NAME}/dgraph" \
    --version "$CHART_VERSION" \
    -n "$namespace" \
    -f "$values" \
    --wait --timeout 15m

  # CI publishes ca.crt as the Envoy backend. Same live-cluster exception as
  # certificate.yaml above: this is not a build artifact. HTTPRoutes are owned
  # by carverauto/gitops (Argo) and must not be applied from this script.
  if [[ -f "${here}/${env}/ca-bundle.yaml" ]]; then
    kubectl apply -f "${here}/${env}/ca-bundle.yaml"
  fi

  echo
  echo "deployed. ACL IS ENABLED: clients authenticate as groot, whose initial password is"
  echo "Dgraph's default until it is changed. check with:"
  echo "  kubectl get pods -n ${namespace} -l app.kubernetes.io/name=dgraph"
  echo "  kubectl exec -n ${namespace} ${RELEASE_NAME}-dgraph-alpha-0 -- dgraph version"
}

case "${1:-}" in
  ci)     deploy ci   dgraph-ci ;;
  demo)   deploy demo dgraph ;;
  mirror) mirror_images ;;
  *)      usage ;;
esac
