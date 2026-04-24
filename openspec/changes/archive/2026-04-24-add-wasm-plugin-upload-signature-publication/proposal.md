# Change: Add Wasm plugin upload-signature publication

## Why

First-party Wasm plugins are now published to Harbor as Cosign-signed OCI artifacts, but the control-plane plugin approval flow also supports a separate Ed25519 upload-signature policy for uploaded packages. Today the release pipeline does not publish or verify that second signature for first-party Wasm plugin artifacts, so Harbor publication does not fully satisfy the package-verification contract used by `web-ng`.

## What Changes

- Publish an Ed25519 upload-signature sidecar for each first-party Wasm plugin OCI artifact.
- Define a stable OCI representation for the upload-signature metadata that stays compatible with the existing plugin bundle contract.
- Add release/build verification so Wasm artifact publication fails when the upload-signature sidecar is missing or invalid.
- Add operator configuration for the upload-signing key identity and trusted public key material.

## Impact

- Affected specs: `wasm-plugin-system`
- Affected code:
  - `build/wasm_plugins/**`
  - `scripts/push_all_wasm_plugins.sh`
  - `scripts/sign-wasm-plugin-publish.sh`
  - `scripts/verify-wasm-plugin-publish.sh`
  - `.forgejo/workflows/release.yml`
  - `build/buildbuddy/release_pipeline.sh`
  - docs for Wasm plugin publication and verification
