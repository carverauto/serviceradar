## Context
Mapper discovery currently runs as a standalone `serviceradar-mapper` service with its own config path and deployment targets. The agent already includes mapper-related code paths and checker registration, but config and results routing are split across services. The new approach embeds mapper execution in the agent and uses the agent-gateway/core-elx gRPC channel for config and result ingestion.

## Goals / Non-Goals
- Goals:
  - Remove the standalone mapper deployment and consolidate discovery execution into `serviceradar-agent`.
  - Use agent-gateway/core-elx for mapper job config delivery and result submission.
  - Provide a first-class UI workflow for discovery jobs, credentials, and schedules.
  - Store discovery credentials securely with AshCloak in CNPG.
- Non-Goals:
  - Redesign the mapper discovery algorithms.
  - Change discovery data models beyond what is needed for job definition, scheduling, and result ingestion.
  - Introduce multi-tenant bypass modes or alternative credential stores.

## Decisions
- Decision: Represent mapper discovery jobs as Ash resources in web-ng/core-elx, compiled into agent-consumable config via the existing agent config compiler path.
  - Rationale: Aligns with the agent-config specification and existing patterns for config compilation and caching.
- Decision: Submit mapper discovery results through agent-gateway gRPC using a dedicated results type (or method) that routes into core ingestion.
  - Rationale: Keeps edge → platform communication consistent with existing gRPC results pipelines and avoids NATS-only paths.
- Decision: Store SNMP and API credentials with AshCloak encryption in CNPG.
  - Rationale: Keeps secrets in the same data plane as other configuration while meeting security requirements for at-rest encryption.
- Decision: Place discovery job management under Settings → Networks → Discovery, in a dedicated tab for mapper jobs.
  - Rationale: Keeps discovery workflows alongside existing network settings and reduces UI fragmentation.
- Decision: Persist mapper interfaces/topology in CNPG and project relationship data into an Apache AGE graph.
  - Rationale: Keeps raw discovery data queryable via Ash while enabling graph traversal for topology views.

## Risks / Trade-offs
- Removing the standalone mapper service is a breaking deployment change; upgrades must remove the mapper workload and its config artifacts.
- Migrating existing mapper config from KV into Ash resources requires a clear migration plan to avoid losing operator-managed settings.
- Agent resource usage may increase because mapper discovery runs alongside other checks; scheduling and concurrency controls should be considered.
- AGE graph writes add extra ingestion work; batching and idempotency are required to avoid graph bloat or contention.

## Migration Plan
- Add a one-time migration path that reads existing mapper KV config (if present) and materializes discovery jobs/credentials in CNPG.
- Update deployment manifests to remove mapper workloads and related SPIFFE IDs/service accounts.
- Provide upgrade notes instructing operators to retire `serviceradar-mapper` and rely on agent-based discovery.

## Open Questions
- Should legacy `config/mapper.json` continue to be read as a fallback until all tenants are migrated?
- How will mapper job scheduling interact with existing sweep scheduling to avoid overlapping scans?
- Should mapper discovery results be persisted in new tables or reuse existing device discovery streams?
- How should long-running discovery jobs report progress and partial results?
- Are there existing UI flows (Configuration Management) that must be kept in sync or deprecated?
- What node/edge labels and key fields should the AGE graph standardize on for devices and interfaces?
