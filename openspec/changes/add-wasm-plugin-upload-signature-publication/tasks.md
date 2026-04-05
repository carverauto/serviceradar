## 1. Implementation

- [x] 1.1 Add a helper that computes the `web-ng` upload-signature payload from a first-party plugin manifest and Wasm content hash.
- [x] 1.2 Add release/build signing logic for first-party Wasm plugins using a dedicated Ed25519 upload-signing key.
- [x] 1.3 Publish upload-signature metadata as an additional OCI layer on each Wasm plugin artifact.
- [x] 1.4 Verify the upload-signature sidecar during local and CI Wasm publication verification.
- [x] 1.5 Wire the required env vars/secrets into Forgejo and BuildBuddy release flows.
- [x] 1.6 Document the release signing inputs and `PLUGIN_TRUSTED_UPLOAD_SIGNING_KEYS` operator configuration.

## 2. Validation

- [x] 2.1 Run shell/script syntax checks for the touched release and Wasm publication scripts.
- [x] 2.2 Run strict OpenSpec validation for this change.
- [x] 2.3 Perform a dry-run or local verification proving the upload-signature sidecar is emitted and validated for a first-party Wasm plugin artifact.
