# Self-Hosted Sigstore Trust Material

This directory is the stable repository-owned location for ServiceRadar's
custom Sigstore trust material once keyless signing is enabled for releases.

Current state:

- OCI release signing uses a Cosign-compatible public key published at
  `docs/cosign.pub`.
- The intended long-term release signer is the OpenBao Transit-backed
  `hashivault://cosign-release` key exposed to Forgejo runner jobs.
- Full self-hosted keyless signing remains blocked by the deployed Forgejo
  `14.0.3` release, which does not yet expose Forgejo Actions OIDC.

Populate these files from the active Fulcio/Rekor deployment:

- `trusted-root.json`: preferred Cosign trusted-root document for keyless verification
- `fulcio-root.pem`: optional out-of-band Fulcio root certificate
- `ctfe.pub`: optional out-of-band CT log public key
- `rekor.pub`: optional out-of-band Rekor public key

The release and verification scripts prefer `trusted-root.json` when present.
The PEM/public-key files are fallback material for environments that are not yet
using a full trusted-root document.

## Issuer design note

Fulcio does not accept arbitrary OIDC claim shapes blindly. The issuer you trust
for keyless signing needs to emit claims that Fulcio can map into a certificate
SAN and that you can later constrain with Cosign verification policy.

Before locking the issuer choice, inspect the workflow token claims with:

```bash
./scripts/inspect-actions-oidc.sh | jq .
```

If the raw Forgejo Actions token does not map cleanly to the Fulcio issuer mode
you choose, use Authentik or another federation layer to mint a Fulcio-friendly
subject instead of hardcoding policy around an incompatible token shape.

## CI/CD configuration

Forgejo workflows and local helpers support these variables for self-hosted
keyless signing:

- `SIGSTORE_FULCIO_URL`
- `SIGSTORE_REKOR_URL`
- `SIGSTORE_OIDC_ISSUER`
- `SIGSTORE_OIDC_CLIENT_ID`
- `SIGSTORE_OIDC_AUDIENCE`
- `SIGSTORE_TRUSTED_ROOT` or `SIGSTORE_TRUSTED_ROOT_FILE`
- `SIGSTORE_ROOT_PEM` or `SIGSTORE_ROOT_FILE`
- `SIGSTORE_CT_LOG_PUBLIC_KEY` or `SIGSTORE_CT_LOG_PUBLIC_KEY_FILE`
- `SIGSTORE_REKOR_PUBLIC_KEY_PEM` or `SIGSTORE_REKOR_PUBLIC_KEY_FILE`
- `COSIGN_CERTIFICATE_IDENTITY` or `COSIGN_CERTIFICATE_IDENTITY_REGEXP`
- `COSIGN_CERTIFICATE_OIDC_ISSUER` or `COSIGN_CERTIFICATE_OIDC_ISSUER_REGEXP`

In Forgejo Actions, `id-token: write` must be granted to the job so the runner
can mint an OIDC token for Cosign.

## Verification example

```bash
cosign verify \
  --experimental-oci11 \
  --trusted-root docs/sigstore/trusted-root.json \
  --certificate-identity-regexp '<issuer-specific SAN regex>' \
  --certificate-oidc-issuer https://issuer.example.com \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:sha-<commit>
```

Until the custom Sigstore stack is active for releases, the legacy
`docs/cosign.pub` key remains the verification path for existing key-based
signatures.
