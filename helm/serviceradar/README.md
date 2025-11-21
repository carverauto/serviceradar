# ServiceRadar Helm Chart (Preview)

This chart packages the ServiceRadar demo stack for Helm-based installs.

Status: scaffolded. It includes:
- Ingress template driven by values.yaml
- DB Event Writer ConfigMap

Planned next: port all base resources from k8s/demo/base into templates/.

Usage:

1) Install chart:
  helm install serviceradar ./helm/serviceradar \
    -n serviceradar-staging --create-namespace \
    --set ingress.host=staging.serviceradar.cloud

Notes:
- A pre-install hook auto-generates `serviceradar-secrets` (JWT/API key, admin password + bcrypt hash) unless you disable it with `--set secrets.autoGenerate=false`. If you disable it, create the secret yourself at `secrets.existingSecretName` (default `serviceradar-secrets`).
- The chart does not generate image pull secrets; create `ghcr-io-cred` (or override `image.registryPullSecret`).
- The SPIRE controller manager sidecar can be disabled with `--set spire.controllerManager.enabled=false` if you do not need webhook-managed entries.

Notes:
- As we port resources, image tags and other settings will be configurable via values.
