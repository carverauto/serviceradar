## Context
- core-elx logs `permission denied for schema serviceradar` when projecting mapper topology into the AGE graph.
- The graph name is hard-coded to `serviceradar`, which creates a separate schema and requires explicit grants that are not consistently applied.
- Dedicated AGE schemas avoid polluting `platform` while still keeping graph tables out of `public`.

## Goals / Non-Goals
Goals:
- Use a single canonical AGE graph name across core-elx and SRQL in a dedicated schema.
- Ensure the application role has USAGE/ALL privileges on the AGE graph schema at startup.
- Retire legacy graph names so reads and writes converge on one graph.

Non-Goals:
- Preserve graph data across the rename (topology is derived and can be rebuilt).
- Change SRQL query semantics beyond graph name alignment.
- Introduce multi-tenant or per-gateway graphs.

## Decisions
- Canonical graph name: `platform_graph`.
  - Rationale: AGE graph schemas are named after the graph; using `platform_graph` isolates graph tables from the `platform` schema while avoiding `public`.
- Add a configuration knob for the graph name with `platform_graph` as the default.
- Migrations will create the canonical graph (if missing) and leave legacy graphs (`serviceradar`, `serviceradar_topology`) untouched.
- Startup migrations will grant USAGE/ALL privileges on the `platform_graph` schema to the application role using the admin connection, and log when admin credentials are unavailable.

## Risks / Trade-offs
- Legacy graphs remain for safety; mapper re-projection repopulates the canonical graph.
- Environments without admin credentials could still miss schema grants; mitigated by ensuring the canonical graph is created by the application role during migrations when possible.

## Migration Plan
1. Create migration to ensure the `platform_graph` graph exists (legacy graphs remain).
2. Update core-elx and SRQL to use the canonical graph name.
3. Trigger mapper ingestion to rebuild topology graph content.
4. Verify graph upserts succeed without schema permission errors.

## Open Questions
- Confirm the preferred environment variable name for the graph setting.
