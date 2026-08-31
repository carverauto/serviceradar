# Self-Hosted Sigstore Trust Material

This directory is the stable repository-owned location for ServiceRadar's
custom Sigstore trust material once keyless signing is enabled for releases.

Current state:

- OCI release signing uses a Cosign-compatible public key published at
  `docs/cosign.pub`.
- The intended long-term release signer is the OpenBao Transit-backed
  `hashivault://cosign-release` key exposed to GitHub Actions runner jobs.
- Full self-hosted keyless signing needs Actions OIDC that Fulcio can
  map into a certificate SAN. Use `scripts/inspect-actions-oidc.sh` to
  inspect the token before locking issuer policy.

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

If the raw GitHub Actions token does not map cleanly to the Fulcio issuer mode
you choose, use Authentik or another federation layer to mint a Fulcio-friendly
subject instead of hardcoding policy around an incompatible token shape.

## CI/CD configuration

GitHub Actions workflows and local helpers support these variables for
self-hosted keyless signing:

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

In GitHub Actions, `id-token: write` must be granted to the job so the runner
can mint an OIDC token for Cosign.

## OpenBao signing boundary

GitHub Actions runners only need OpenBao access for the OCI signing step. They
must not receive general OpenBao access or reusable signing key material.

Current hardening requirements:

- Release jobs use the OpenBao Transit-backed `hashivault://cosign-release` key
  for signing. The matching public key is the one used by Kyverno admission in
  the `demo` namespace.
- CI workflows must authenticate to OpenBao immediately before signing. The
  token must stay in the current shell step and must not be written to
  `GITHUB_ENV`.
- GitHub Actions workflows must not expose `COSIGN_PRIVATE_KEY` or
  `COSIGN_PASSWORD` as job-wide environment variables. CI signing uses the
  centrally managed OpenBao key.
- The OpenBao role used by runners should be bound to a dedicated signing
  runner service account, preferably in a protected signing environment, not a
  shared runner service account that executes arbitrary jobs.
- The OpenBao policy should be sign-only for the release key. It should not
  allow key read/export/update/delete, arbitrary Transit paths, or KV access.
- The token TTL should be as short as practical for the signing step, and the
  role should bind service account name, namespace, and audience where OpenBao
  supports it.

A runner compromise during a signing job can still sign whatever that job can
push to the registry. Treat the signer and registry credentials as one trust
boundary: protect branch/tag publishing, keep release environments approval
gated, and prefer a dedicated signing runner over a general runner pool.

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
