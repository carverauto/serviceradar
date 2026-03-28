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
- Ensure the control plane has the trusted Ed25519 public key configured before operators publish releases.
- Ensure every managed agent has the trusted Ed25519 public key configured through `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` or a build-time `ReleaseSigningPublicKey` injection.
- Publish artifacts over HTTPS.
- Include per-platform artifact metadata in the release manifest, including `os`, `arch`, `url`, `sha256`, and optional `format` and `entrypoint`.
- If repository-hosted release assets redirect to object storage or a CDN, keep the redirect chain on HTTPS. The control plane mirrors those artifacts into internal storage at publish time, and agents still reject insecure redirects, digest mismatches, and manifest-signature failures.

## Publish A Release

Use the authenticated release-management page:

- Open `/settings/agents/releases`.
- For production releases, prefer `Import Repository Release`. The page automatically loads the latest repository releases for the selected GitHub or Forgejo repo and lets operators import a ready release with one click when the configured manifest and signature assets are present.
- If the desired release is older than the recent list or uses a custom tag workflow, use the specific-tag import field and point it at the repo-hosted release tag plus the signed manifest asset and signature asset names.
- For developer and local validation workflows, keep using `Publish Release Manually` and enter the semantic version, release notes, manifest signature, artifact URL, SHA256 digest, OS, architecture, and artifact format directly.
- Publish the release.

The control plane stores:

- the desired version,
- the signed manifest,
- rollout eligibility metadata for supported agent platforms,
- internal object-store references for each mirrored rollout artifact.

The current implementation expects the manifest signature field to contain the Ed25519 signature for the canonical manifest JSON. The control plane mirrors the referenced artifacts into internal datasvc-backed object storage, and the agent verifies that same signature before staging any artifact fetched through `agent-gateway`.

Recommended repository-release asset convention:

- `serviceradar-agent-release-manifest.json`
- `serviceradar-agent-release-manifest.sig`
- `serviceradar-agent_<version>_linux_amd64.tar.gz`

The manifest asset should contain the full multi-platform release manifest, including the final artifact URLs, SHA256 digests, platform metadata, and optional `format` / `entrypoint` fields.

The GitHub release pipeline now publishes these assets automatically when `SERVICERADAR_AGENT_RELEASE_PRIVATE_KEY` is configured for the release job. Manual repository releases must attach the same three assets for one-click import to work.

## Signing Key Handling

Keep signing private keys out of the fleet.

Recommended handling:

- Sign release manifests in CI or an offline release workflow.
- Distribute only the public verification key to agents.
- Rotate the public key by shipping a new package-managed agent/updater build before switching signing infrastructure.
- Never reuse the release-management UI as the source of truth for private signing material.

Relevant agent settings:

- `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`: trusted Ed25519 public key used by the control plane and agents to verify release manifests.
- `SERVICERADAR_AGENT_RUNTIME_ROOT`: optional override for the mutable runtime payload root.
- `SERVICERADAR_AGENT_UPDATER`: optional override for the updater binary path.
- `SERVICERADAR_AGENT_SEED_BINARY`: optional override for the package-owned seed agent binary.

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
- The rollout command points the agent at an authenticated HTTPS download path on `agent-gateway`, not at the original GitHub/Forgejo/Harbor host.
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
