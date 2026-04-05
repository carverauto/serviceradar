# Sigstore Deployment Notes

This directory contains the repo-owned bootstrap for a self-hosted Sigstore
deployment in the existing Kubernetes cluster.

## Current design

- Namespace: `sigstore-system`
- Public hostnames:
  - `fulcio.serviceradar.cloud`
  - `rekor.serviceradar.cloud`
- North-south routing:
  - `HTTPRoute` resources attach to the existing
    `serviceradar-system/serviceradar-shared-gateway`
  - the namespace is labeled with `serviceradar.com/gateway-access: "true"`
- Helm charts:
  - `sigstore/fulcio`
  - `sigstore/rekor`
- Trust publication:
  - repo path [docs/sigstore/README.md](/home/mfreeman/src/serviceradar/docs/sigstore/README.md)

## Important constraint

Do not deploy Fulcio issuer policy blindly. First run the manual Forgejo
workflow [inspect-oidc.yml](/home/mfreeman/src/serviceradar/.forgejo/workflows/inspect-oidc.yml)
and inspect the real token claims with:

```bash
fj actions tasks -r carverauto/serviceradar
```

Then update [fulcio-values.yaml](/home/mfreeman/src/serviceradar/k8s/sigstore/fulcio-values.yaml)
so `OIDCIssuers` and `MetaIssuers` match the actual claims and issuer shape.

## Bootstrap vs production

The current Rekor values file is configured for a persistent secret-backed PEM
signer:

- signer path: `/var/run/rekor-signer/private.pem`
- secret name: `rekor-signer`

This is better than the chart default `memory`, but it is still bootstrap-grade.
Upstream Rekor explicitly treats memory and file-based signers as testing
mechanisms. The production target should be a KMS-backed signer URI such as:

- `awskms://...`
- `gcpkms://...`
- `hashivault://...`

Until a KMS backend is chosen, you can stand up Rekor with a secret-backed key
to validate the rest of the flow, but do not call that the final state.

## Required secrets

Before installation:

1. Create the Fulcio CA secret expected by the chart:
   - secret: `fulcio-server-secret`
   - namespace: `sigstore-system`
   - keys:
     - `private`
     - `cert`
     - `password`

2. Create the Rekor signer secret:
   - secret: `rekor-signer`
   - namespace: `sigstore-system`
   - key:
     - `private.pem`

## Install commands

```bash
kubectl apply -k k8s/sigstore

helm upgrade --install fulcio sigstore/fulcio \
  -n sigstore-system \
  -f k8s/sigstore/fulcio-values.yaml

helm upgrade --install rekor sigstore/rekor \
  -n sigstore-system \
  -f k8s/sigstore/rekor-values.yaml
```

## Post-install work

1. Export trust material from the active deployment.
2. Populate `docs/sigstore/` with:
   - `trusted-root.json`
   - `fulcio-root.pem`
   - `ctfe.pub`
   - `rekor.pub`
3. Add Forgejo Actions secrets:
   - `SIGSTORE_FULCIO_URL`
   - `SIGSTORE_REKOR_URL`
   - `SIGSTORE_OIDC_ISSUER`
   - `SIGSTORE_OIDC_CLIENT_ID`
   - `SIGSTORE_OIDC_AUDIENCE`
   - `SIGSTORE_TRUSTED_ROOT`
   - `COSIGN_CERTIFICATE_IDENTITY` or `COSIGN_CERTIFICATE_IDENTITY_REGEXP`
   - `COSIGN_CERTIFICATE_OIDC_ISSUER` or `COSIGN_CERTIFICATE_OIDC_ISSUER_REGEXP`
4. Only after that, retry the image publish workflow.
