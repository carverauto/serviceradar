#!/usr/bin/env bash

# Reset the Proton Timeplus datastore by rotating its PVC and restarting core.
# Usage:
#   scripts/reset-proton.sh [namespace]
# Environment overrides:
#   KUBECTL        Path to kubectl (default: kubectl)
#   PVC_NAME       Proton PVC name (default: serviceradar-proton-data)
#   DEPLOY_NAME    Proton deployment (default: serviceradar-proton)
#   CORE_DEPLOY    Core deployment (default: serviceradar-core)
#   STORAGE_CLASS  StorageClass for the replacement PVC (default: local-path)
#   PVC_SIZE       Requested storage size (default: 512Gi)

set -euo pipefail

ns="${1:-demo}"
kubectl_bin="${KUBECTL:-kubectl}"
pvc_name="${PVC_NAME:-serviceradar-proton-data}"
deploy_name="${DEPLOY_NAME:-serviceradar-proton}"
core_deploy="${CORE_DEPLOY:-serviceradar-core}"
storage_class="${STORAGE_CLASS:-local-path}"
pvc_size="${PVC_SIZE:-512Gi}"

log() {
  printf '[reset-proton] %s\n' "$*"
}

run_kubectl() {
  "${kubectl_bin}" -n "${ns}" "$@"
}

log "Scaling ${deploy_name} to 0"
run_kubectl scale deployment/"${deploy_name}" --replicas=0
run_kubectl rollout status deployment/"${deploy_name}" --timeout=5m

log "Deleting PVC ${pvc_name}"
run_kubectl delete pvc "${pvc_name}" --ignore-not-found --wait=true

log "Recreating PVC ${pvc_name} (${pvc_size}, storageClass=${storage_class})"
cat <<EOF | "${kubectl_bin}" apply -n "${ns}" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  labels:
    app.kubernetes.io/part-of: serviceradar
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${pvc_size}
  storageClassName: ${storage_class}
EOF

log "Scaling ${deploy_name} back to 1"
run_kubectl scale deployment/"${deploy_name}" --replicas=1
run_kubectl rollout status deployment/"${deploy_name}" --timeout=5m

log "Restarting ${core_deploy} to rebuild Proton schema"
run_kubectl rollout restart deployment/"${core_deploy}"
run_kubectl rollout status deployment/"${core_deploy}" --timeout=5m

log "Reset complete. Consider checking OTEL counts via proton-client or /api/query."
