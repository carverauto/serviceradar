## Context
Edge collectors currently inherit KV-backed configuration behavior via shared config bootstrap utilities. This adds dependency on NATS/JetStream KV and complicates config compiler logic in the control plane, even though edge collector configs are effectively static or already delivered through gRPC (serviceradar-agent).

## Goals / Non-Goals
- Goals:
  - Remove KV configuration dependencies from all services.
  - Simplify shared config utilities by trimming KV-only code paths.
- Non-Goals:
  - Remove KV configuration support from control-plane services.
  - Change elixir-based services (explicitly out of scope).
  - Redesign the AgentConfig gRPC schema.

## Decisions
- Decision: No services read, seed, or watch KV for service configuration. Zen continues to read rules from KV but not its service configuration, and SRQL may still read API keys from KV.
  - Rationale: Static config or gRPC configuration is sufficient for service config, and removing KV config eliminates a dependency chain on NATS and config compilers while preserving required KV-backed rules delivery for zen.
- Decision: Config source for edge collectors is explicit and limited to file-based JSON/YAML or gRPC-delivered configs (for agent-managed collectors).
  - Rationale: Makes configuration behavior predictable and reduces runtime complexity.

## Risks / Trade-offs
- Breaking change for deployments that relied on KV for edge collectors. Mitigation: Provide migration guidance and ensure defaults exist in file configs.
- Potential dependency removal (e.g., `rust/kvutil`) might impact other services. Mitigation: audit for remaining consumers and only remove when unused.

## Migration Plan
1. Inventory services that currently depend on KV config and identify their runtime config sources.
2. Update each service to read from local JSON/YAML or gRPC-provided config only.
3. Remove KV watchers/seeding hooks from shared config libraries.
4. Update Compose/bootstrap docs and sample configs to include file-based defaults.
5. Ship release notes calling out the breaking change and required config migration.

## Open Questions
- Confirm the final list of services to remove KV config from and whether any still require dynamic updates.
- Determine whether any services still depend on `rust/kvutil` after cleanup.
