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

The release and verification scripts prefer `trusted-root.json` when present.
The PEM/public-key files are fallback material for environments that are not yet
using a full trusted-root document.

## Pinned Rekor keys (transparency-log receipts)

Release signatures for images, native add-ons and Wasm plugins are logged in the
public-good Rekor v1 log, and each classic `.sig` carries that log's receipt
(see "Transparency-log receipts and the signing ledger" in
[RELEASE_PUBLISHING.md](../RELEASE_PUBLISHING.md)). Two committed files pin the
log keys the receipts are checked against:

- `rekor-keys/<logID>.pub`: every accepted Rekor v1 public key, one PEM file per
  log, named by the log ID (hex SHA-256 of the key's DER encoding). Release
  verification selects the file by the receipt's `logID` and passes it to cosign
  as `SIGSTORE_REKOR_PUBLIC_KEY`, so no TUF lookup and no online log lookup
  happens. A receipt whose log ID has no file here fails.
- `rekor.pub`: the key of the log the signer writes to now, byte-identical to
  its file in `rekor-keys/`. The signer refuses an upload response whose log ID
  is not this key's.

`//build/contracts:rekor_key_consistency_test` checks that every file in
`rekor-keys/` is named by its log ID and that `rekor.pub` is a member of the set.

The initial key is the public-good log `c0d23d6ad406973f9559f3ba2d1ca01f84147d8ffc5b8445c224f98b9591801d`,
taken from Sigstore's TUF-signed `trusted_root.json` (the `tlogs` entry with base
URL `https://rekor.sigstore.dev`), not from a Rekor API response. It was read on
2026-11-17 from TUF root version 16, targets version 14, with
`trusted_root.json` SHA-256
`6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66`.

Updating the keys: when Sigstore adds a Rekor v1 key, sets an end date on the
pinned one, or removes it, add the new key as `rekor-keys/<logID>.pub` from the
TUF trusted root in a reviewed PR, keep every key an accepted receipt names, and
point `rekor.pub` at the log the signer writes to from then on. Never drop a key
from `rekor-keys/` that a published receipt names: verification of that
receipt would then fail.

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

GitHub Actions runners only need OpenBao access for Transit operations in a
release publish: Wasm upload signatures, OCI signing, release `SHA256SUMS`
signing, and signature verification. They must not receive general OpenBao access or reusable signing
key material.

Current hardening requirements:

- Release jobs use the OpenBao Transit-backed `hashivault://cosign-release` key
  for signing. The matching public key is the one used by Kyverno admission in
  the `demo` namespace.
- CI workflows must authenticate to OpenBao immediately before each Transit
  use (Wasm upload signatures, signing, and verification), after compilation
  has finished. The release checksum signer
  (`scripts/sign-release-checksums.sh`) logs in itself, after the packages
  are built. The token TTL covers that Transit phase only. The token must
  stay in the current shell step and must not be written to `GITHUB_ENV`.
- GitHub Actions workflows must not expose `COSIGN_PRIVATE_KEY` or
  `COSIGN_PASSWORD` as job-wide environment variables. CI signing uses the
  centrally managed OpenBao key.
- The OpenBao role used by runners should be bound to a dedicated signing
  runner service account, preferably in a protected signing environment, not a
  shared runner service account that executes arbitrary jobs.
- The OpenBao policy should be sign-only for the release key. It should not
  allow key read/export/update/delete, arbitrary Transit paths, or KV access.
- The token TTL should be as short as practical for one Transit phase, and the
  role should bind service account name, namespace, and audience where OpenBao
  supports it.

A runner compromise during a signing job can still sign whatever that job can
push to the registry. Treat the signer and registry credentials as one trust
boundary: protect branch/tag publishing, keep release environments approval
gated, and prefer a dedicated signing runner over a general runner pool.

## Verifying published images

Every published image carries one classic Cosign `.sig` signature, which every
Cosign version checks by default, so no extra format flags are needed. Verify a
released or immutable tag with the public key in
[docs/cosign.pub](../cosign.pub):

```bash
cosign verify \
  --key docs/cosign.pub \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:v<version>
```

For an exact build, prefer the immutable `sha-<commit>` tag:

```bash
cosign verify \
  --key docs/cosign.pub \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:sha-<commit>
```

Successful verification proves the image was signed with the ServiceRadar
release key and that the signature published in Harbor matches the requested
image. A sigstore-bundle (OCI referrer) signature without the classic `.sig` is
not a valid ServiceRadar signature: cluster admission reads only the classic
`.sig` and rejects such an image.

Until the custom Sigstore stack is active for releases, `docs/cosign.pub`
remains the verification path. Once keyless signing is enabled, verify against
the published trusted root and an issuer/identity constraint instead:

```bash
cosign verify \
  --trusted-root docs/sigstore/trusted-root.json \
  --certificate-identity-regexp '<issuer-specific SAN regex>' \
  --certificate-oidc-issuer https://issuer.example.com \
  registry.carverauto.dev/serviceradar/serviceradar-core-elx:sha-<commit>
```
