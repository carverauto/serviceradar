## Context
Managed agent rollouts already require a release-signing public key on each agent host. Packaged agents have an existing environment override path at `/etc/serviceradar/kv-overrides.env`, but edge onboarding currently only provisions `agent.json` and mTLS materials.

## Goals / Non-Goals
- Goals:
  - Provision the release verification key automatically for newly onboarded agents.
  - Reuse the existing packaged-agent environment override path.
  - Avoid widening the minimal bootstrap config contract for `agent.json`.
- Non-Goals:
  - Changing release signature validation semantics.
  - Changing rollout UX or manual release publishing.
  - Requiring release management to be enabled in every environment.

## Decisions
- Decision: Carry the release verification key in a separate overrides file within the onboarding bundle instead of adding it to `agent.json`.
  - Rationale: `agent.json` is intentionally minimal and focused on connectivity/bootstrap settings. The release verification key is operational environment state, not connection bootstrap state.
- Decision: Persist the key into the standard package-owned overrides file.
  - Rationale: packaged agents already load `/etc/serviceradar/kv-overrides.env`, so onboarding should feed the same path instead of inventing a second runtime location.
- Decision: Omit the override file content when no public key is configured.
  - Rationale: this preserves existing onboarding behavior in environments that are not yet using managed release rollouts.

## Risks / Trade-offs
- Writing the overrides file must avoid clobbering unrelated environment entries.
  - Mitigation: update only the relevant key and preserve other lines.
- Operators may assume onboarding backfills already-installed agents.
  - Mitigation: document that this automation applies to newly downloaded onboarding bundles and re-enrollment flows.
