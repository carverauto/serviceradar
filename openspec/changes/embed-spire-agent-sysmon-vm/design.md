## Context
- sysmon-vm needs a SPIFFE identity on laptops (Docker or VM) without relying on a pre-installed poller/agent SPIRE workload socket or shared host volumes.
- Current checker onboarding assumes a workload API is available; `pkg/edgeonboarding` stubs out SPIRE address resolution and checker config, and sysmon-vm today only consumes a static JSON config.
- We want a near zero-touch install: user provides `ONBOARDING_TOKEN` (or `ONBOARDING_PACKAGE`) + `KV_ENDPOINT`, launches sysmon-vm, and it joins the demo SPIRE server over the network, publishes a local workload socket, and becomes reachable by the demo poller/core.
- Target platforms: macOS arm64 and Linux; runtime is Docker-first (standalone container) with an opt-in path to reuse a poller SPIRE proxy over TCP when explicitly provided.

## Goals / Non-Goals
- Goals: embed a SPIRE workload agent inside sysmon-vm (no external install), join demo SPIRE via LB host/port using the package join token/bundle, expose a workload API socket locally, and activate the checker package in Core.
- Non-Goals: run a nested SPIRE server, change poller/agent bootstrap flows, or add a generic “install SPIRE on the host” step.

## Decisions
- Embedded agent: link a SPIRE workload agent into sysmon-vm and start it in-process (spawned with generated config) when no workload API override is provided. Use join_token node attestation with trust bundle + parent ID from the checker package.
- Address selection: pull SPIRE upstream address/port from package metadata (LB IP/port for demo), with env overrides (`SPIRE_UPSTREAM_ADDRESS`, `SPIRE_UPSTREAM_PORT`) and an explicit workload API override (`SPIRE_WORKLOAD_API`) to skip the embedded agent when a poller proxy is available.
- Config layout: `pkg/edgeonboarding` will emit agent config under the storage path (`/var/lib/serviceradar/spire/agent.conf`), write join token + bundle, start the embedded agent, and publish the workload socket path into the generated checker config so sysmon-vm can bind with an SVID.
- Packaging: macOS arm64 and Linux builds of sysmon-vm must include the embedded agent bits; packaging scripts will stay in sync (no extra install step).

## Risks / Trade-offs
- SPIRE agent as a library may lag upstream changes; keep config minimal (join_token, disk key manager, unix workload attestor) to reduce churn.
- Laptop firewalls may block the upstream SPIRE port; document the required LB host/port and provide clear errors.
- Join token TTL: if expired before first run, onboarding fails; rely on package reissue/rotation and surface clear logs.

## Migration Plan
1) Extend edge onboarding packages for `checker:sysmon-vm` to include upstream host/port, parent ID, trust bundle, and join token.
2) Implement embedded agent runner in `pkg/edgeonboarding` (generate config, write assets, spawn agent, wait for workload socket).
3) Wire sysmon-vm main to start onboarding → embedded agent → bind gRPC with the issued SVID; keep legacy config path when no token/package is provided.
4) Update Docker/macOS run docs to highlight `ONBOARDING_TOKEN` + `KV_ENDPOINT` as the happy path and `SPIRE_WORKLOAD_API` as an override.
5) Validate e2e against the demo namespace and document troubleshooting/rotation.

## Open Questions
- Confirm parent/selector for the sysmon-vm checker entry in demo (likely a dedicated parent ID vs. generic checker parent).
- Whether we need a TCP workload proxy mode in the demo poller to help hosts where local sockets are difficult (fallback only; default is embedded agent).
