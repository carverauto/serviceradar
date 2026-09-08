## Context

Agent config is assembled from multiple resource families: sweep groups, mapper jobs, plugin assignments, SNMP/sysmon settings, and sync integration sources. Today those dependencies are spread across generators, notifiers, and gateway command calls. Adding a new UI-backed resource requires engineers to remember every config side effect manually.

The immediate production symptom was Armis: credentials were edited in the UI, but agent behavior showed the served sync config did not contain the credential shape needed by the running agent. The bug fix restores the current path, but the broader failure mode remains: there is no single source of truth listing which resources affect which agent configs.

## Goals / Non-Goals

- Goals:
  - Make agent config dependencies explicit and reviewable.
  - Ensure UI saves for agent-affecting resources trigger the correct config invalidation or push behavior.
  - Support resource-specific affected-agent selection so unrelated agents are not forced to reload.
  - Preserve existing agent config payload schemas unless a separate proposal changes them.
  - Provide tests and diagnostics that catch missing catalog entries.
- Non-Goals:
  - Replace the existing `AgentConfigGenerator` payload format.
  - Introduce multitenancy or per-customer routing.
  - Store decrypted secrets in diagnostics, logs, or catalog metadata.
  - Implement a new durable config store beyond existing compiled config/version behavior.

## Decisions

- Decision: implement the catalog as project-owned Elixir modules/data, not database rows.
  - Rationale: config dependencies are code-level contracts between resources, compilers, and gateway behavior. Keeping them in code makes review, test coverage, and release coordination straightforward.
- Decision: catalog entries declare resource module, action classes, config type, dependency compiler, affected-agent resolver, and push/invalidation strategy.
  - Rationale: these are the pieces currently scattered across notifiers and generators.
- Decision: affected-agent resolution is explicit per entry.
  - Rationale: some resources are assigned to one agent, while others affect all agents or a computed subset. This prevents global pushes becoming the default for every change.
- Decision: secret handling is declared as metadata and enforced in diagnostics/tests.
  - Rationale: config payloads may intentionally contain secrets for edge execution, but logs and UI diagnostics must only show presence/fingerprint/redacted status.

## Risks / Trade-offs

- Risk: catalog entries drift from generator behavior.
  - Mitigation: add tests that compare generator-declared dependencies with catalog coverage.
- Risk: affected-agent resolvers become slow for broad resources.
  - Mitigation: require resolvers to be query-backed and covered by focused tests; allow entries to opt into scoped global refresh only when justified.
- Risk: diagnostics accidentally reveal credential values.
  - Mitigation: catalog diagnostics only expose secret presence, redacted field names, hashes, and affected config version IDs.

## Migration Plan

1. Introduce the catalog and register existing resource dependencies with behavior-preserving entries.
2. Move one-off notifier calls to a shared catalog dispatcher.
3. Add coverage tests for known config dependencies, including integration sources and plugin assignments.
4. Add diagnostics for recent config-affecting saves and affected agents/config versions.
5. Remove duplicated ad hoc trigger paths after parity tests pass.

## Open Questions

- Should the catalog dispatcher immediately push connected agents, only invalidate versions, or support both per entry?
- Should generator modules declare dependencies directly, or should tests maintain a separate known-generator dependency list?
- Which diagnostics belong in web-ng versus operator CLI output?
