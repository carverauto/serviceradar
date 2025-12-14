## Context
ServiceRadar has a mapper/discovery engine (`serviceradar-mapper`) and an SNMP checker service (`serviceradar-snmp-checker`). Both services are registered with KV-backed config descriptors:
- Mapper: `config/mapper.json`
- SNMP checker: `config/snmp-checker.json`

The web UI already includes a Network → Discovery view that can display discovered devices and interfaces, but operators cannot:
1) configure mapper seeds from the UI, or
2) enable/disable SNMP interface metric polling from the UI.

Additionally, current services appear to detect KV config updates but log that a restart is required to apply changes, which must be made explicit in the UI/API behavior.

## Goals / Non-Goals
- Goals:
  - Provide an admin UI workflow to configure mapper discovery seeds and related discovery settings.
  - Provide an admin UI workflow to enable/disable SNMP metric polling per discovered interface.
  - Use Core as the authoritative API/write path; the browser does not write KV directly.
  - Ensure sensitive values are redacted on read and not leaked to the browser.
- Non-Goals:
  - Full “network automation” workflows beyond seed/router discovery and interface SNMP polling toggles.
  - A full-fledged RBAC redesign; use existing authZ primitives (admin-only if needed).

## Decisions
- Decision: Locate controls under Network → Discovery (not Settings).
  - Rationale: The configuration is contextual to discovery results (seed router → discovered interfaces → polling toggles).

- Decision: Reuse existing “admin config” plumbing for mapper config.
  - UI calls `GET/PUT /api/admin/config/mapper` (Next.js route), which proxies to Core `GET/PUT /api/admin/config/mapper` with `X-API-Key` + bearer auth.
  - Core persists mapper config to KV `config/mapper.json` via the existing config descriptor machinery.
  - Rationale: this is already the repository’s canonical “UI edits KV-backed service config” pathway (used by the Settings/Admin UI).

- Decision: Persist per-interface SNMP polling preferences in KV keyed by a stable interface identifier.
  - Approach: store one KV entry per interface preference under a dedicated prefix (exact key format TBD), rather than a single large blob.
  - Rationale: config and operator-driven preferences are managed in KV across ServiceRadar; per-interface storage avoids “giant JSON merge” failure modes.

- Decision: Proxy all browser reads/writes through Next.js API routes.
  - Approach: the browser calls `web/src/app/api/*` routes which forward to Core with `X-API-Key` + bearer auth (and optionally fall back to the access token cookie).
  - Rationale: matches existing patterns in the Settings/Admin UI, avoids exposing internal service addresses to the browser, and centralizes auth forwarding.

## Risks / Trade-offs
- Restart semantics: if mapper/snmp-checker do not hot-apply config changes, UI must communicate “pending restart” clearly; otherwise users will assume changes are live.
- Scale: storing per-interface preferences in a single JSON blob risks exceeding KV entry size limits and making merges/error recovery difficult; per-interface KV keys mitigate this.
- Identity: interfaces need a stable identifier (likely `(device_id, if_index)`), but device identity must be consistent between discovery results, SNMP targets, and stored preferences.

## Migration Plan
- MVP:
  - Add Core APIs + UI for mapper seed configuration and interface SNMP preference toggles.
  - Persist mapper config into KV.
  - Implement a KV-backed preference store for per-interface toggles with a clear “effective config” derivation step.
  - Document if/when service restart is required for changes to take effect.
- Follow-up (optional):
  - Hot-reload support for mapper and/or snmp-checker for relevant config subsets.
  - Bulk actions (enable/disable polling by device, by interface status/type).

## Open Questions
- How does mapper discovery output map to a stable interface identifier used elsewhere (CNPG tables, SNMP metric dimensions)?
- What is the desired propagation mechanism from interface toggles → SNMP polling behavior (restart vs live apply)?
- Should “enable SNMP polling” imply creating SNMP targets for the owning device, and if so, what credential source is used?
