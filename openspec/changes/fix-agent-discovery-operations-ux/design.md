## Context
The Proxmox integration added credential rules, candidate probing, and agent-scoped plugin assignment, but the demo feedback exposed missing operational polish around the agent pages and candidate discovery flow. The most important behavioral correction is separating unauthenticated PVE fingerprinting from authenticated credential trials.

Current storage uses `ocsf_agents.host` for source host/address data, while the current spec and parts of SRQL/UI expect `ocsf_agents.ip` as a distinct address field. The agent detail page also mixes persisted registry data with live connected-agent state and release rollout state, which causes unknown placeholders even when the control plane has enough information elsewhere.

## Goals
- Operators can navigate to `/agents` directly from the main app shell.
- `/agents` and `/agents/:uid` work against the deployed OCSF agent schema without selecting missing columns.
- Agent detail pages show useful release and service-check state for real agents.
- Credential rule forms guide users toward valid agent scope values.
- Agent and plugin-assignment selection lists exclude stale historical agents unless the user intentionally views historical records.
- First-party plugin repository views default to the latest indexed release and preserve access to older release manifests through an explicit selector.
- Imported plugin package blobs use NATS Object Store only; no application-facing filesystem blob backend remains.
- Web-ng database usage does not create repeated Postgrex `client exited` disconnect churn during normal agent/plugin/release operations.
- Proxmox candidate discovery can find likely PVEs without already having Proxmox credentials.
- Credential leakage risk remains bounded: credential trials are opt-in and scoped.

## Non-Goals
- Do not implement TPM/enclave-backed credential brokering in this change.
- Do not auto-configure syslog/vector/log forwarding for Proxmox hosts.
- Do not broaden credential trials beyond explicitly configured rule scope.
- Do not replace SRQL; shortcut searches compile into SRQL before execution.

## Decisions
- Decision: Store both agent hostname/source host and numeric source IP.
  - Rationale: Operators need both values. `host` can carry hostname/listen host context, while `ip` carries the source address used for filtering, display, and network assignment.
- Decision: Candidate discovery is driven by mapper job scope, not credential rule existence.
  - Rationale: Operators need to discover PVE candidates before choosing credentials. Unauthenticated fingerprinting against configured job seeds is the lowest-risk discovery path.
- Decision: Credential auto-discovery means "try this credential against scoped discovered candidates", not "scan everywhere".
  - Rationale: This matches the credential leakage concern and keeps dangerous behavior behind an explicit setting.
- Decision: Agent detail release data should combine persisted `ocsf_agents` rollout fields with latest rollout target rows and live control-stream metadata.
  - Rationale: The details page is an operational status page; showing `Unknown` when related state exists elsewhere is misleading.
- Decision: Service checks on agent detail should use existing service/check registrations assigned to that agent, not infer them only from static config.
  - Rationale: Operators care about the effective checks currently associated with the agent.
- Decision: Stale agent cleanup should run server-side and selection UIs should additionally filter by active/recent status.
  - Rationale: A prune job prevents long-term registry buildup, while UI filtering prevents stale rows from showing up before the next pruning cycle.
- Decision: The first-party repository plugin list should group by release and default to the newest indexed release.
  - Rationale: Operators usually assign current plugins; historical plugin entries are still useful for diagnosis but should not dominate the table.
- Decision: Remove filesystem plugin blob storage as a supported app mode and require NATS Object Store for persistence.
  - Rationale: Kubernetes pods are ephemeral, filesystem blob paths create writable-volume requirements, and retaining unused storage modes becomes tech debt.
- Decision: Treat high-volume Postgrex `client exited` disconnect logs as a defect.
  - Rationale: Occasional cancellation can happen, but repeated pool-wide churn points to query/task lifecycle problems and makes operational logs noisy.

## Risks / Trade-offs
- Supporting `ip` as an alias can hide schema drift if used forever.
  - Mitigation: document `host` as canonical and keep `ip` alias only at SRQL/UI compatibility boundaries.
- Unauthenticated candidate probing still touches network endpoints on port 8006.
  - Mitigation: require mapper job seed/SRQL/agent scope and record evidence metadata so operators can audit why a candidate was marked.
- Agent detail hydration may require multiple reads.
  - Mitigation: use bounded reads by agent uid and keep list pages SRQL-backed.

## Migration Plan
1. Add/restore `ocsf_agents.ip` and update writes so agent rows contain both `host` and `ip`.
2. Update agent navigation and detail hydration.
3. Update credential rule form and validation tests.
4. Add stale agent pruning/filtering and first-party plugin release grouping.
5. Move plugin blob persistence to NATS Object Store-only storage.
6. Correct mapper Proxmox candidate probe gating and add tests around credential-free candidate marking versus opt-in credential trials.
7. Diagnose and fix web-ng DB connection churn.
8. Deploy to demo and verify `agent-sr-test-pve04` details, service checks, release fields, agent/plugin settings, plugin import, and PVE candidate discovery.
