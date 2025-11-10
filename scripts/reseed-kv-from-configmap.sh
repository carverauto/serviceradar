#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
CONFIGMAP="${CONFIGMAP:-serviceradar-config}"
BUCKET="${BUCKET:-serviceradar-datasvc}"
TOOLS_SELECTOR="${TOOLS_SELECTOR:-app=serviceradar-tools}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 1
fi

mapfile -t FILES < <(
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' "$@"
  else
    kubectl get configmap "${CONFIGMAP}" -n "${NAMESPACE}" -o yaml |
      python - <<'PY'
import sys, yaml
doc = yaml.safe_load(sys.stdin)
keys = sorted(k for k in doc.get("data", {}) if k.endswith(".json"))
print("\n".join(keys))
PY
  fi
)

if [[ "${#FILES[@]}" -eq 0 ]]; then
  echo "No JSON entries found in ${CONFIGMAP}" >&2
  exit 1
fi

TOOLS_POD="$(kubectl get pods -n "${NAMESPACE}" -l "${TOOLS_SELECTOR}" -o jsonpath='{.items[0].metadata.name}')"

for file in "${FILES[@]}"; do
  key_path="${file//./\\.}"
  tmp="$(mktemp)"
  kubectl get configmap "${CONFIGMAP}" -n "${NAMESPACE}" -o "jsonpath={.data.${key_path}}" >"${tmp}"
  kubectl cp "${tmp}" "${NAMESPACE}/${TOOLS_POD}:/tmp/${file}" >/dev/null
  kubectl exec -n "${NAMESPACE}" "${TOOLS_POD}" -- sh -c "nats kv put ${BUCKET} config/${file} < /tmp/${file}"
  rm -f "${tmp}"
done
