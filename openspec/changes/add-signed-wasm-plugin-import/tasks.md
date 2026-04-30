## 1. Repository Publication
- [x] 1.1 Define the first-party Wasm plugin import index schema, including plugin ID, version, bundle OCI reference, OCI digest, bundle digest, upload-signature metadata reference, display/config sidecar metadata, release tag, and publication timestamp.
- [x] 1.2 Update the Forgejo release workflow to upload the import index asset with release artifacts.
- [x] 1.3 Extend Wasm plugin signing/verification scripts so the index fails verification when an artifact, Cosign signature, Rekor entry, or upload-signature sidecar is missing or mismatched.
- [x] 1.4 Document the release asset names and local verification commands in `docs/docs/wasm-plugins.md`.

## 2. Importer Backend
- [x] 2.1 Add `platform` schema migration(s) for first-party plugin import source metadata and sync status.
- [x] 2.2 Implement a Forgejo release/index discovery module using the pinned Forgejo host and bounded release fetch policy.
- [x] 2.3 Implement OCI artifact fetch and verification for Cosign signatures, Rekor metadata, digest matching, and upload-signature sidecar validation.
- [x] 2.4 Mirror verified bundle contents into the configured plugin storage backend using the existing package/bundle validation path.
- [x] 2.5 Stage imported packages with source metadata and deduplicate by plugin ID, version, and artifact digest.
- [x] 2.6 Add manual sync and scheduled automatic sync entry points; ensure automatic sync stages only and does not approve or assign packages.

## 3. UI / API
- [x] 3.1 Extend plugin package API/context functions to list discovered first-party plugin releases and import status.
- [x] 3.2 Update the plugin package LiveView to show first-party repository plugins, verification state, source release, available versions, and import actions.
- [x] 3.3 Show imported first-party package provenance and verification details in the package detail/review modal.
- [x] 3.4 Keep approval/denial/revocation flows unchanged for imported packages and preserve RBAC checks for view, stage, approve, and assign actions.

## 4. Tests / Validation
- [x] 4.1 Add Elixir unit tests for Forgejo index discovery, URL validation, redirect rejection, malformed index rejection, and importer deduplication.
- [x] 4.2 Add verification tests for invalid Cosign/upload-signature metadata and mismatched OCI or bundle digests.
- [x] 4.3 Add LiveView tests for first-party plugin discovery, import success/error states, and package provenance display.
- [x] 4.4 Run `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix` and focused `elixir/serviceradar_core` tests for plugin resources/importer logic. Full quality was executed; remaining failures are pre-existing Credo findings outside this change, and focused checks for touched plugin files pass.
- [x] 4.5 Use `$playwright-cli` to capture plugin UI screenshots after local or demo validation.
- [ ] 4.6 Use `$demo-local-rollout` for demo validation after implementation approval; use `$demo-web-ng-fastpath` only if the final implementation touches `elixir/web-ng/**` exclusively.
- [x] 4.7 Run `openspec validate add-signed-wasm-plugin-import --strict`.
