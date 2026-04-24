## Context
ServiceRadar already has a signed Harbor publication path for container images, but first-party Wasm plugins are still built manually with shell scripts such as:

- `go/tools/wasm-plugin-harness/build.sh`
- `go/cmd/wasm-plugins/axis/build.sh`

Those scripts emit local `dist/plugin.wasm` artifacts and optional sidecar files, but they do not produce Bazel-managed outputs, OCI publication metadata, or Cosign signatures. At the same time, the plugin system already defines a bundle-oriented package format (`plugin.yaml`, `plugin.wasm`, optional schemas/contracts), and cluster admission policy now expects Rekor-backed signatures for first-party artifacts.

## Goals / Non-Goals
- Goals:
  - Build first-party Wasm plugin bundles through Bazel.
  - Publish those bundles to Harbor with immutable tags that match commit/release workflows.
  - Require the same Cosign + Rekor verification standard used by cluster policy.
  - Keep the published artifact compatible with the existing plugin import bundle format.
  - Support standard OCI inspection/pull workflows for operators and developers.
- Non-Goals:
  - Change the Wasm runtime ABI or plugin execution model.
  - Replace the plugin approval/import workflow in this change.
  - Design a plugin marketplace or automatic sync-from-Harbor flow in this change.

## Decisions
- Decision: The canonical published unit is a plugin bundle artifact, not a loose `.wasm` blob.
  - The OCI artifact payload SHALL contain the same importable bundle shape used by the plugin system: manifest, Wasm binary, and optional sidecars.
  - This keeps first-party publication aligned with control-plane validation and future import automation.

- Decision: Bazel owns build orchestration and publish entrypoints.
  - Bazel SHALL compile the Wasm payload, assemble the bundle, and expose deterministic publish targets for each first-party plugin.
  - If `rules_oci` is insufficient for generic OCI artifact publishing, a Bazel-owned wrapper around `oras` is acceptable as an implementation detail.

- Decision: Harbor publication uses deterministic repository naming and immutable tags.
  - Each first-party plugin SHALL publish to a stable Harbor repository path under the ServiceRadar project.
  - Publication SHALL include at least an immutable `sha-<commit>` tag.
  - Release/version tags MAY be added by the same workflow when a stable release exists.

- Decision: Wasm plugin artifacts use the same Cosign trust contract as images.
  - Published plugin artifacts SHALL be signed with the repository Cosign key.
  - Rekor/tlog upload SHALL be enabled by default so local verification matches Kyverno enforcement.
  - Local verification tooling SHALL fail if an artifact is missing the expected signature or Rekor entry.

- Decision: ORAS is a supported operator tool, not the primary product contract.
  - Operators and developers MAY inspect and pull published plugin artifacts with `oras`.
  - Product documentation SHALL describe the OCI reference and verification flow without requiring bespoke registry APIs.

## Risks / Trade-offs
- `rules_oci` is image-centric, so generic OCI artifact publication may require a small custom Bazel wrapper.
  - Mitigation: keep the external contract at the OpenSpec level focused on artifact shape, tags, and signatures rather than on a specific Bazel rule implementation.
- Publishing complete bundles increases artifact size versus a naked `.wasm` blob.
  - Mitigation: the bundle stays aligned with the import/distribution contract and avoids secondary metadata channels.
- Existing manual `build.sh` workflows may drift during migration.
  - Mitigation: convert them into thin wrappers over Bazel or remove them after Bazel becomes the single supported path.

## Migration Plan
1. Add Bazel targets for current first-party plugins and emit bundle artifacts plus digests.
2. Add Harbor publication targets and signing/verification support for Wasm plugin artifacts.
3. Update docs to point developers at Bazel/OCI workflows.
4. Deprecate manual shell builds once Bazel parity is verified.

## Open Questions
- Should published plugin artifacts live in a nested Harbor path such as `registry.carverauto.dev/serviceradar/plugins/<plugin-id>` or in a flat repository naming scheme?
- Do we want release automation to publish version tags for plugins immediately, or start with commit tags only and add release aliases later?
