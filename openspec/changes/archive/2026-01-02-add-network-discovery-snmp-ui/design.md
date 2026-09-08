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
- Decision: Split “contextual” vs “authoritative” configuration surfaces.
  - Network → Discovery is the contextual workflow (discovery results + interface-level toggles).
  - Settings → Configuration Management is the authoritative workflow for service configs (mapper + snmp-checker), including full credential and job configuration.
  - Rationale: Discovery operations are best understood next to discovery results, but service configuration needs a predictable, centralized place and must not require raw JSON authoring for common cases.

- Decision: Reuse existing “admin config” plumbing for mapper config.
  - UI calls `GET/PUT /api/admin/config/mapper` (Next.js route), which proxies to Core `GET/PUT /api/admin/config/mapper` with `X-API-Key` + bearer auth.
  - Core persists mapper config to KV `config/mapper.json` via the existing config descriptor machinery.
  - Rationale: this is already the repository’s canonical “UI edits KV-backed service config” pathway (used by the Settings/Admin UI).

- Decision: Surface `snmp-checker` in Configuration Management as a first-class global service.
  - Approach: ensure the UI navigation includes the globally-scoped config descriptor `snmp-checker`, and provide a typed editor for common fields with an “Advanced JSON” escape hatch.
  - Rationale: operators must be able to configure SNMP credentials/targets without hunting for hidden service types or editing large JSON blobs.

- Decision: Persist per-interface SNMP polling preferences in KV keyed by a stable interface identifier.
  - Approach: store one KV entry per interface preference under a dedicated prefix (exact key format TBD), rather than a single large blob.
  - Rationale: config and operator-driven preferences are managed in KV across ServiceRadar; per-interface storage avoids “giant JSON merge” failure modes.

- Decision: Derive effective SNMP checker targets from preferences in Core.
  - Approach: Core writes managed targets into `config/snmp-checker.json` based on enabled interface preferences, keeping any non-managed targets intact.
  - Rationale: Core is already the authoritative KV write path; this keeps the browser from writing KV and centralizes target generation logic.

- Decision: Introduce a UI-level “Check Kind” abstraction for poller checks.
  - Approach: the poller configuration editor presents a dropdown of supported check kinds (e.g. Sysmon (gRPC), ICMP, SNMP, Mapper discovery status) and maps the selection into the existing `service_type` + `service_name` + `details` fields.
  - Rationale: “gRPC” is an implementation detail; operators should configure intents (sysmon, mapper discovery, etc.) instead of assembling opaque tuples or pasting JSON into `details`.

- Decision: Redact sensitive configuration on read and preserve redacted values on write.
  - Approach: Core redacts sensitive keys in `GET /api/admin/config/{service}` responses for `mapper` and `snmp-checker`, and restores redacted placeholders on `PUT`.
  - Rationale: allows UI-driven edits without exposing or clobbering secrets.

- Decision: Proxy all browser reads/writes through Next.js API routes.
  - Approach: the browser calls `web/src/app/api/*` routes which forward to Core with `X-API-Key` + bearer auth (and optionally fall back to the access token cookie).
  - Rationale: matches existing patterns in the Settings/Admin UI, avoids exposing internal service addresses to the browser, and centralizes auth forwarding.

## Risks / Trade-offs
- Restart semantics: if mapper/snmp-checker do not hot-apply config changes, UI must communicate “pending restart” clearly; otherwise users will assume changes are live.
- Scale: storing per-interface preferences in a single JSON blob risks exceeding KV entry size limits and making merges/error recovery difficult; per-interface KV keys mitigate this.
- Identity: interfaces need a stable identifier (likely `(device_id, if_index)`), but device identity must be consistent between discovery results, SNMP targets, and stored preferences.
- UX drift: a UI-level “check kind” map can drift from backend-supported checkers if not anchored to config descriptors or a backend-provided enum/list.

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
- What is the canonical list of supported poller check kinds, and should Core expose this list (and per-kind schemas) to prevent UI/backend drift?

## Local Testing Notes
- Local docker-compose can run without committing secrets by using a gitignored `docker-compose.override.yml` to KV-enable `snmp-checker` and pin `:local` images built via Bazel `oci_load` targets.
- Secrets (e.g. UniFi API keys, SNMP communities) should be set at runtime via Core admin config APIs and never written to tracked files.
