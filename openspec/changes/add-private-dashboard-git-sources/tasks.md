## 1. Specification And Design
- [x] 1.1 Document the private dashboard Git source proposal.
- [x] 1.2 Define UI and package-source requirements.
- [ ] 1.3 Review and approve the proposal before implementation.

## 2. Data Model And Security
- [ ] 2.1 Add a dashboard Git source resource/table with repo URL, provider, public key, encrypted private key reference, known host metadata, status, and audit timestamps.
- [ ] 2.2 Implement server-side Ed25519 keypair generation and key rotation.
- [ ] 2.3 Store private keys through the existing encrypted credential/secret mechanism and redact private material from all reads, logs, and audit payloads.
- [ ] 2.4 Enforce host allowlisting and known-host verification for SSH imports.

## 3. Import Backend
- [ ] 3.1 Add a private Git fetcher that shallow-fetches a requested ref into a temporary directory using the stored deploy key.
- [ ] 3.2 Resolve refs to immutable commit SHAs before reading artifacts.
- [ ] 3.3 Reuse existing manifest validation, renderer digest validation, artifact size limits, source metadata, and route binding checks.
- [ ] 3.4 Reject absolute paths, path traversal, symlink escapes, missing manifests, missing renderers, and oversized artifacts.

## 4. Admin UI And API
- [ ] 4.1 Add UI to create a dashboard Git source and copy its generated public deploy key.
- [ ] 4.2 Add UI to test source connectivity, rotate the deploy key, and revoke/delete a source.
- [ ] 4.3 Extend the dashboard package import modal to select a private Git source and import by ref/manifest path.
- [ ] 4.4 Add API support for source creation/test/rotation and private-source dashboard import.

## 5. Tests And Validation
- [ ] 5.1 Add unit tests for key generation, key redaction, and path normalization.
- [ ] 5.2 Add integration tests for private Git import success and failure cases.
- [ ] 5.3 Add LiveView tests for source creation, public key display, source selection, and import errors.
- [ ] 5.4 Run focused Elixir quality and relevant web-ng tests.
