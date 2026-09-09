# Agent Release Management

ServiceRadar agent release management lets operators publish a signed agent release, roll it out to a selected cohort, and rely on automatic rollback when the updated runtime does not come back healthy in time.

This runbook covers:

- publishing a release into the control plane,
- configuring the agent verification key,
- rollout guardrails for canary and broad fleet updates,
- rollback and diagnostics during a failed rollout.

## Prerequisites

Before using release management in production:

- Install agents with the package-managed launcher and updater layout.
- Ensure the agent runtime host has write access to `/var/lib/serviceradar/agent/releases` or the override set by `SERVICERADAR_AGENT_RUNTIME_ROOT`.
- For Helm-managed in-cluster agents, keep `agent.runtimeStorage.enabled=true` so `/var/lib/serviceradar/agent` is backed by a PVC instead of pod ephemeral storage.
- Ensure the control plane has the trusted Ed25519 public key configured before operators publish releases.
- Ensure every managed agent package embeds the trusted Ed25519 public key. It is compiled in from the committed `go/pkg/agent/release_signing_key.txt`, so every build carries it; the release workflow asserts that the committed value matches the key derived from the signing secret.
- Publish artifacts over HTTPS.
- Include per-platform artifact metadata in the release manifest, including `os`, `arch`, `url`, `sha256`, and optional `format`, `entrypoint`, `capabilities`, `helper_protocol_version`, `compatible_agent_versions`, `checksums`, `signatures`, `sbom`, `license_review`, and `deployment_requirements`.
- If repository-hosted release assets redirect to object storage or a CDN, keep the redirect chain on HTTPS. The control plane mirrors those artifacts into internal storage at publish time, and agents still reject insecure redirects, digest mismatches, and manifest-signature failures.

## Prepare a reviewed agent test artifact

For an unpublished base-agent build, dispatch `.github/workflows/native-addons.yml`
with `mode=agent-test-artifact` from the reviewed branch and set `expected_commit`
to its full commit SHA. The workflow rejects a mismatch with its own SHA. Operators
must configure the HTTPS `AGENT_TEST_ARTIFACT_BASE_URL` variable in the protected
`release` environment; dispatch inputs cannot choose an arbitrary artifact origin.

This mode builds only the declared Linux amd64 agent runtime archive. It derives
a unique prerelease version without changing `VERSION` or creating a release tag,
executes the packaged binary's `--version`, and signs the canonical manifest at
runtime with the protected release key. The signature is verified against the
committed agent public root; signing material is never a Bazel action input.
The verified archive, manifest, signature, and metadata are uploaded as workflow
artifacts retained for seven days.

The workflow does not host the archive at its manifest URL, publish it into
ServiceRadar, or roll out agents. After validation, place the archive at the
exact signed URL and use the publication and rollout steps below. Building a
Kubernetes agent image alone does not update native agents running plugin runners.

## Publish A Release

Use the authenticated release-management page:

- Open `/settings/agents/releases`.
- For production releases, prefer `Import Repository Release`. The page automatically loads the latest five repository releases for the selected GitHub repo, and lets operators import a ready release with one click when the configured manifest and signature assets are present.
- The published-release list also shows only the latest five releases. Older artifacts can remain protected in object storage when referenced by active or paused rollouts, but they are intentionally not shown as primary operator choices.
- If the desired release is older than the recent list or uses a custom tag workflow, use the specific-tag import field and point it at the repo-hosted release tag plus the signed manifest asset and signature asset names.
- For developer and local validation workflows, keep using `Publish Release Manually` and enter the semantic version, release notes, manifest signature, artifact URL, SHA256 digest, OS, architecture, and artifact format directly.
- Publish the release.

This page is for base `serviceradar-agent` runtime releases. Native add-on packages
such as `netprobe` and `workload-identity` are reviewed, approved, and assigned from
[Native Add-ons](./native-addons.md) in **Settings > Agents > Add-ons**. Keeping the
catalogs separate prevents add-on package versions from hiding the agent releases
operators expect to roll out from this page.

The control plane stores:

- the desired version,
- the signed manifest,
- rollout eligibility metadata for supported agent platforms,
- internal object-store references for each mirrored rollout artifact.

The current implementation expects the manifest signature field to contain the Ed25519 signature for the canonical manifest JSON. The control plane mirrors the referenced artifacts into internal datasvc-backed object storage, and the agent verifies that same signature before staging any artifact fetched through `agent-gateway`.

Security guardrails:

- Repository import only trusts GitHub-owned release hosts.
- Import and mirroring reject non-HTTPS, loopback, link-local, private-network, and unresolved destinations.
- Provider auth tokens are not forwarded to untrusted asset hosts.

Recommended repository-release asset convention:

- `serviceradar-agent-release-manifest.json`
- `serviceradar-agent-release-manifest.sig`
- `serviceradar-agent_<version>_linux_amd64.tar.gz`

The manifest asset should contain the full multi-platform release manifest, including the final artifact URLs, SHA256 digests, and platform metadata. Base agent artifacts should use `capabilities: ["agent"]`. Optional capability helpers are not bundled into alternate managed-agent runtimes; publish them as native add-ons with their own signed artifacts and discovery index entries.

The GitHub release pipeline now publishes these assets automatically when `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` is configured for the release job. Manual repository releases must attach the same three assets for one-click import to work. RDP helper delivery uses the `rdp` native add-on artifact instead of a `serviceradar-agent-rdp_*` runtime archive.

## Signing Key Handling

Keep signing private keys out of the fleet.

Recommended handling:

- Sign release manifests in CI or an offline release workflow.
- Distribute only the public verification key to agents.
- Rotate the public key by shipping a new package-managed agent/updater build before switching signing infrastructure.
- Never reuse the release-management UI as the source of truth for private signing material.

Relevant agent settings:

- Package-managed agents verify release manifests with the build-time embedded `ReleaseSigningPublicKey`.
- Package-managed agents use fixed package-owned paths for the updater, seed binary, and mutable runtime root.
- The control plane still reads `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` at runtime for release import and validation.
- RDP-capable agent/helper artifacts must declare `remote_access.rdp` in their manifest `capabilities`.
- RDP helper artifacts that carry a placeholder or fail-closed connector must mark `deployment_requirements.release_phase` as `experimental`, set `helper_connector_ready` to `false`, and require the helper readiness probe. EdgeOps may show these only to RDP-enabled deployments, but installed agents must not advertise `remote_access.rdp` until the local helper `--capabilities` probe reports `connector_ready: true`. When readiness is false, preserve the helper's `connector_ready_reason` in operator-facing diagnostics.
- RDP-capable artifacts are hidden from the EdgeOps release catalog and rejected by rollout artifact selection unless `SERVICERADAR_REMOTE_ACCESS_DESKTOP_RDP_ENABLED=true`.
- One-click rollout commands include an RDP helper install plan only for the selected signed artifact that declares `remote_access.rdp`; base-agent rollouts omit helper installation metadata.
- Keep the default base-agent release artifact free of the IronRDP helper so standard deployments do not install desktop remote-access components.

Onboarding propagation:

- Agent onboarding bundles do not distribute the managed release verification key for package-managed agents.
- `srctl enroll --core-url ... --token ...` preserves unrelated `/etc/serviceradar/kv-overrides.env` entries, but protected agent release trust keys are ignored if they appear in a bundle.

Migration guidance:

- Older hosts may still carry `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` in `/etc/serviceradar/kv-overrides.env`.
- After upgrading to a hardened package-managed agent build, those stale entries no longer define the managed release trust anchor.

## Rollout Guardrails

Prefer controlled staged rollouts over broad fleet pushes.

Recommended operator workflow:

1. Publish the release.
2. Create a canary rollout from `/settings/agents/releases` with a small explicit cohort.
3. Use `batch_size: 1` or another small batch for the first rollout.
4. Leave a non-zero `batch_delay_seconds` when validating a new train in production.
5. Use the rollout compatibility preview on `/settings/agents/releases` to confirm the selected cohort resolves to known agents and matches the published platform set before starting the rollout. The page disables rollout submission for unresolved agent IDs, empty cohorts, or unsupported platforms, and the control plane also rejects those invalid cohorts at submit time.
6. Watch `/agents` for version distribution, rollout-state counts, and per-agent target version drift.
7. Pause the rollout immediately if agents begin failing verification, restart, or health checks.
8. Resume only after the failure mode is understood.

Operational guidance:

- Keep cohorts explicit and audit-friendly.
- Do not mix unrelated platform variants in the same canary unless you have validated artifact coverage for each one.
- Treat digest mismatch or signature verification failures as release-pipeline problems, not agent-host problems, until proven otherwise.
- Use cancel only to stop undispatched targets; already running targets will continue until they reach a terminal state.

## Rollback Behavior

Agent activation uses a separate updater and a stable package-managed launcher.

Runtime behavior:

- The agent stages the verified payload under the mutable runtime root.
- The rollout command points the agent at an authenticated HTTPS download path on `agent-gateway`, not at the original GitHub or Harbor host.
- `agent-gateway` resolves the authorized rollout target, fetches the mirrored object from internal storage, and streams it back to the agent.
- The updater switches the `current` symlink atomically to the new versioned payload.
- The service restarts against the new runtime.
- If the updated agent does not report healthy before the reconnect deadline, the updater restores the previous target and restarts again.

The control plane records terminal per-agent states such as:

- `healthy`
- `failed`
- `rolled_back`
- `canceled`

## Diagnostics

Use these surfaces first during rollout triage:

- `/settings/agents/releases`: published releases, supported platform badges, rollout compatibility preview, disabled invalid rollout submission, rollout-creation validation, recent rollouts, pause/resume/cancel actions, and per-target diagnostics.
- `/agents`: version distribution, rollout-state counts, target-version filtering, per-agent last update error.
- `/agents/:uid`: current version, desired version, rollout state, last update error, and recent rollout targets.

Common failure patterns:

- Invalid signature: the agent rejected the manifest before staging.
- Digest mismatch: the downloaded artifact did not match the published SHA256.
- No matching artifact: the control plane could not select an artifact for the agent's `os` and `arch`. The releases page surfaces this as `no matching release artifact for agent platform <os>/<arch>` and highlights the affected target as an unsupported platform.
- Unresolved custom IDs: the rollout cohort includes agent IDs that do not currently resolve to inventory records, so rollout creation is rejected until those entries are corrected.
- Rolled back: the updater switched versions, but the new runtime did not become healthy before the deadline.

## Recovery Playbook

When a rollout is unhealthy:

1. Pause the rollout.
2. Inspect `last_update_error` and the per-agent target state.
3. If failures are verification-related, fix the manifest, signature, or artifact publication and publish a corrected version instead of reusing the broken one.
4. If failures are post-restart regressions, let the automatic rollback settle and confirm agents return to the previous version.
5. Start a fresh canary rollout for the corrected release.

Do not manually mutate files under the package-managed launcher paths during incident response. ServiceRadar-managed runtime payloads are the mutable layer; launcher, unit files, and baseline updater assets remain package-owned.
