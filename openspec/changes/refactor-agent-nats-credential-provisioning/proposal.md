# Change: Remove implicit agent NATS credential provisioning

## Why

Agent onboarding currently enqueues a worker that tries to mint a per-agent
NATS JWT even though the default agent and OTLP paths do not require direct
NATS access. The worker reads `:nats_account_name` and
`:nats_account_seed`, but those settings are not configured in the deployed
core, so it discards the job with `:nats_not_configured`.

This produced a misleading partial-success state for package
`f8828fb5-1df4-4058-adc8-e82e0825257b` (`vndcngrpexnap01`): the base package
was delivered, but the optional NATS credential was absent. The credential
belonged to a now-retired host-slice canary that granted experimental
per-agent publication to `flow.host-slice.<agent-id>`; it is not required by
the deployed OTLP or flow-attribution paths. Today raw sampled flows travel
through the normal central/internal flow pipeline, while the agent sends local
process attribution to the gateway as `FlowAttributionEventBatch` payloads on
the dedicated `StreamStatus` path. Core persists that attribution in
`platform.flow_process_attribution_current` and correlates it with sampled
flows in CNPG.

## What Changes

- Make ordinary agent onboarding independent of NATS account configuration
  and per-agent NATS credentials.
- Remove the implicit per-agent NATS provisioning dependency from the base
  agent package lifecycle; a delivered package without a NATS credential is a
  valid base onboarding result.
- Keep the default OTLP transport on the durable agent-to-gateway relay, with
  no NATS credential or central NATS endpoint on the agent.
- Treat direct NATS access as an explicit, opt-in edge capability that is
  valid only when a site-local NATS leaf is registered and configured.
- Provision any direct-leaf authentication on demand through the add-on
  configuration lifecycle, scoped to the leaf and add-on. It SHALL NOT place
  a central platform account seed or broad central NATS credential in the
  base onboarding bundle.
- Remove or retire the unused agent-side flow NATS publisher/bootstrap path
  left by the retired host-slice canary. Preserve the deployed split: raw
  sampled flows use the normal central/internal flow pipeline; local
  attribution uses agent-to-gateway `StreamStatus` with
  `FlowAttributionEventBatch`; and core persists and correlates the two in
  CNPG.
- Add migration and recovery handling for existing packages and agents that
  were created with the old optional NATS credential fields.

## Impact

- Affected specs: `edge-onboarding`, `agent-connectivity`,
  `observability-signals`.
- Affected code: edge package delivery and bundle generation, the agent NATS
  publisher/bootstrap configuration, NATS credential provisioning workers,
  direct-to-leaf OTLP configuration, and related tests/runbooks.
- Existing agents using the default gateway-relay path do not need a NATS
  credential to remain operational.
- Existing legacy per-agent NATS credentials require an explicit cleanup and
  revocation migration; they SHALL NOT be silently reissued for new packages.
