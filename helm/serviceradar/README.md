# ServiceRadar Helm Chart

This chart packages the ServiceRadar demo stack for Helm-based installs.

Official chart location (OCI/GHCR):
- Chart: `oci://ghcr.io/carverauto/charts/serviceradar`
- ArgoCD repoURL (no `oci://` prefix): `ghcr.io/carverauto/charts`

Usage:

1) Install from the published OCI chart (recommended):

  helm upgrade --install serviceradar oci://ghcr.io/carverauto/charts/serviceradar \
    --version 1.0.75 \
    -n serviceradar --create-namespace \
    --set global.imageTag="v1.0.75"

2) Install from a repo checkout (development):

  helm upgrade --install serviceradar ./helm/serviceradar \
    -n serviceradar --create-namespace \
    --set global.imageTag="v1.0.75"

Notes:
- Ingress TLS is on by default; adjust `ingress.host`, `ingress.tls.secretName`, or `ingress.tls.clusterIssuer` as needed for your cluster.
- A pre-install hook auto-generates `serviceradar-secrets` (JWT/API key, admin password + bcrypt hash) unless you disable it with `--set secrets.autoGenerate=false`. If you disable it, create the secret yourself at `secrets.existingSecretName` (default `serviceradar-secrets`).
- The chart does not generate image pull secrets; create `ghcr-io-cred` (or override `image.registryPullSecret`).
- The SPIRE controller manager sidecar can be disabled with `--set spire.controllerManager.enabled=false` if you do not need webhook-managed entries.
