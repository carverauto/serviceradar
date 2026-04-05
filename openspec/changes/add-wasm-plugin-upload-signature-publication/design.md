## Context

`web-ng` enforces uploaded plugin trust with an Ed25519 signature over a canonical payload consisting of:

- the normalized plugin manifest
- the Wasm content hash

That signature is separate from Cosign. Cosign proves the OCI artifact was published by the release pipeline; the upload signature proves the plugin package itself is trusted by the control-plane package policy.

First-party Wasm plugins are currently published as OCI artifacts containing a canonical bundle zip. The current Harbor contract does not include the upload-signature metadata anywhere in the OCI artifact.

## Goals / Non-Goals

- Goals:
  - Publish first-party Wasm OCI artifacts with both Cosign and upload-signature trust material.
  - Preserve the existing canonical bundle zip unchanged as the importable payload.
  - Make verification deterministic in CI and local operator workflows.
- Non-Goals:
  - Add automatic OCI-to-web-ng import in this change.
  - Replace Cosign with the upload signature.
  - Change the existing upload-signature payload semantics used by `web-ng`.

## Decisions

- Decision: The bundle zip remains the canonical payload.
  - The existing bundle layer SHALL stay unchanged so current import validation semantics are preserved.

- Decision: Upload-signature metadata is published as an additional OCI layer.
  - Each first-party Wasm OCI artifact SHALL include a JSON sidecar layer with a dedicated media type.
  - The sidecar SHALL contain the signature metadata expected by the package approval flow:
    - `algorithm`
    - `key_id`
    - `signature`
    - optional `signer`
    - `content_hash`

- Decision: The signed payload matches `web-ng` upload verification.
  - The Ed25519 signature SHALL cover the canonical JSON payload produced from the plugin manifest plus Wasm content hash.
  - CI verification SHALL recompute the payload exactly and fail on any mismatch.

- Decision: Release automation uses a dedicated upload-signing identity.
  - The release pipeline SHALL read a dedicated Ed25519 private key and key identifier from secrets/env vars.
  - Operators SHALL configure the matching public key in `PLUGIN_TRUSTED_UPLOAD_SIGNING_KEYS` for control-plane approval policy.

## Risks / Trade-offs

- This adds a second trust primitive to release automation.
  - Mitigation: keep Cosign and upload-signature verification separate and explicit in scripts/output.
- OCI clients that only inspect the main bundle layer will not automatically notice the upload-signature sidecar.
  - Mitigation: verification tooling and docs must call out the sidecar explicitly.

## Migration Plan

1. Add a signer/verifier helper for first-party Wasm upload signatures.
2. Publish the signature metadata as an OCI sidecar layer on each plugin artifact.
3. Verify the sidecar in local/release workflows.
4. Document the required `PLUGIN_TRUSTED_UPLOAD_SIGNING_KEYS` configuration for `web-ng`.
