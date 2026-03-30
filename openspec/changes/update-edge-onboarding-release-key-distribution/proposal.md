# Change: Distribute the agent release verification key through edge onboarding

## Why
Agent release management now depends on `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` being present on managed agents so they can verify signed release manifests before staging or activation. Today, RPM/DEB installs can be configured manually, but edge onboarding packages do not carry or persist that key, which leaves newly enrolled agents unable to participate safely in managed rollouts without extra operator steps.

The onboarding flow should provision this trust anchor automatically for managed agents while preserving the existing manual developer workflow for local and ad hoc testing.

## What Changes
- Extend edge onboarding bundle generation for agent-capable packages so the bundle can carry the configured agent release verification public key through the package-owned overrides path.
- Extend the agent enrollment flow so downloaded onboarding bundles persist the release verification public key into the standard environment overrides file consumed by packaged agents.
- Keep onboarding compatible with environments that have not configured release management by omitting the override when no public key is configured.
- Preserve the existing manual release publish/import workflows for developers and operators; this change only automates key distribution to onboarded agents.

## Impact
- Affected specs: `edge-onboarding`
- Affected code:
  - `elixir/web-ng`
  - `go/pkg/edgeonboarding`
  - agent onboarding docs and runbooks
