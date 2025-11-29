# Change: Embed SPIRE agent for sysmon-vm edge onboarding

## Why
- Laptop and customer-hosted sysmon-vm deployments run in Docker/VMs without shared volumes, so they cannot rely on an existing poller/agent SPIRE workload socket.
- Current onboarding assumes a locally available SPIRE agent; sysmon-vm needs a zero/near-zero touch path to fetch join material from the demo cluster and mint its own SVID over the network.
- We need a single, guided install flow for customers: provide an onboarding token/package and get an authenticated sysmon-vm checker that the demo (Helm) namespace can adopt automatically.

## What Changes
- Embed a SPIRE workload agent directly into the sysmon-vm binary so it can join the demo SPIRE server over TCP using onboarding tokens, without requiring a prior SPIRE install or shared host sockets (targeting macOS arm64 and Linux builds).
- Extend checker onboarding packages to emit join token/bundle/metadata for sysmon-vm laptop runs and mark activation in Core once the new SPIFFE ID reports in.
- Add Docker-first run guidance (and defaults) so `ONBOARDING_TOKEN` + `KV_ENDPOINT` is sufficient on laptops, while optionally reusing a poller SPIRE proxy when explicitly configured.

## Impact
- Affected specs: edge-onboarding (new).
- Affected code: edge onboarding package API/CLI, `pkg/edgeonboarding` bootstrap, sysmon-vm checker packaging/entrypoint, Docker/Helm run guides for demo adoption.
