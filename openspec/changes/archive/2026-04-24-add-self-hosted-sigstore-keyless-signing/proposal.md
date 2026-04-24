# Change: Add self-hosted Sigstore keyless signing

## Why
ServiceRadar release automation currently depends on static Cosign key material for OCI signing. That is operationally fragile, couples CI to long-lived secrets, and does not align with the repo's existing expectation that published images carry Harbor-visible Cosign signatures and transparent-log verifiability.

Forgejo Actions now supports OIDC ID tokens, and the deployment already has Authentik available. The long-term path is to move release signing to a self-hosted Sigstore stack that trusts Forgejo-issued OIDC identities, with Authentik and/or cluster-managed identity providing the issuer and trust plumbing, rather than storing private signing keys in CI secrets.

## What Changes
- Add a first-class artifact-signing capability spec for OCI and release artifact signing.
- Define a self-hosted Sigstore deployment model for Fulcio, Rekor, and trust-root distribution.
- Define Forgejo Actions keyless signing requirements using OIDC tokens instead of static Cosign private keys.
- Define operator-managed trust material publication for offline/local verification of signed images and artifacts.
- Update release/build pipeline behavior so signing occurs before verification and uses custom Sigstore endpoints/trust roots.

## Impact
- Affected specs: `artifact-signing`
- Affected code:
  - `.forgejo/workflows/release.yml`
  - `.forgejo/workflows/docker-build.yml`
  - `build/buildbuddy/release_pipeline.sh`
  - `scripts/sign-oci-publish.sh`
  - `scripts/verify-oci-publish.sh`
  - release/signing documentation under `docs/`
  - cluster deployment manifests or Helm values for self-hosted Sigstore components
