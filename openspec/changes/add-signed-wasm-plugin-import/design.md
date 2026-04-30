## Context
The repository already publishes first-party Wasm plugin bundles as signed OCI artifacts in Harbor, and the existing specs require upload-signature sidecar metadata compatible with the control-plane plugin upload verification policy. Separately, agent release management imports signed release assets from the pinned Forgejo host and mirrors validated artifacts into internal distribution storage before rollout.

This change connects those two existing surfaces for first-party Wasm plugins: Forgejo remains the release source of truth, Harbor remains the OCI artifact store, and ServiceRadar mirrors verified bundle contents into the configured plugin storage backend before operators approve and assign the package.

## Goals
- Discover first-party Wasm plugin versions from the configured ServiceRadar Forgejo repository release metadata.
- Verify every imported plugin with Cosign plus upload-signature metadata before it enters plugin storage.
- Preserve the staged review and approval workflow for capability and allowlist review.
- Present first-party plugin availability, import status, verification status, and source metadata in the existing plugin UI.
- Support both manual "sync/import now" and scheduled automatic sync.

## Non-Goals
- Do not allow agents to download plugins directly from Forgejo or Harbor.
- Do not replace staged plugin review with automatic assignment.
- Do not introduce a second first-party-only plugin package format.
- Do not add multitenancy or per-customer plugin catalogs.
- Do not make GitHub a supported first-party import provider for this flow.

## Decisions
- Decision: Use Forgejo releases as the discovery surface and Harbor OCI references as the plugin artifact payload surface.
  Rationale: Release management already trusts the pinned Forgejo host, while the Wasm publication pipeline already signs and verifies OCI artifacts in Harbor.

- Decision: Publish a machine-readable first-party plugin import index asset with each release.
  Rationale: The importer should not infer plugin names, bundle paths, signatures, or OCI references from workflow logs. A release asset gives the UI and background sync a stable contract similar to the agent release manifest.

- Decision: Mirror verified bundle contents into the existing plugin package storage backend before marking an import successful.
  Rationale: Agent assignments must continue using internal package references and authenticated internal downloads, not external Forgejo or Harbor URLs.

- Decision: Imported packages remain `staged` unless an operator explicitly approves them.
  Rationale: Signature verification proves provenance and integrity, but capability and allowlist approval is still an operator policy decision.

- Decision: Store source metadata on plugin package versions.
  Rationale: Operators need to audit the release tag, OCI digest, import index entry, signing key identity, verification timestamp, and sync status from the UI and API.

## Risks / Trade-offs
- Risk: Import sync could repeatedly fetch large artifacts.
  Mitigation: Keep an import-state table keyed by plugin ID/version/source digest and skip already mirrored digests.

- Risk: Release indexes could drift from Harbor artifacts.
  Mitigation: Require index digest references to match fetched OCI content and fail closed on mismatch.

- Risk: Automatic import might create assignable plugin packages without review.
  Mitigation: The automatic path only stages verified packages; assignment remains blocked until approval.

- Risk: Verification implementation may duplicate agent release importer fetch policy.
  Mitigation: Share or mirror the same pinned Forgejo host validation, redirect bounds, content size limits, and error reporting patterns from release import.

## Migration Plan
1. Add schema for first-party plugin import source metadata and sync state in the `platform` schema.
2. Add release workflow output for the plugin import index and extend verification to cover it.
3. Add importer service and tests using mocked Forgejo and OCI clients.
4. Extend the plugin package LiveView/API to show discoverable first-party plugins and import/sync state.
5. Validate locally with focused Elixir tests and a Playwright screenshot pass.
6. Roll to `demo` with the appropriate demo rollout skill after implementation approval.

## Open Questions
- Should scheduled sync be enabled by default in demo only, or in all deployments when repository import configuration is present?
- Should a verified first-party update for an already approved plugin version require fresh review if requested capabilities are unchanged?
- Should the import index include all historical first-party plugin versions, or only the release's current tag versions?
