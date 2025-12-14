# Change: Configure mapper discovery + SNMP polling via UI

## Why
- `serviceradar-mapper` and `serviceradar-snmp-checker` are configured via JSON files and KV-backed config keys, but there is no first-class UI workflow for managing discovery seeds or SNMP polling behavior.
- The Network → Discovery UI surfaces discovered devices/interfaces, but it is effectively read-only; operators cannot steer discovery (seed routers) or selectively enable/disable SNMP interface metric polling.
- Mapper and SNMP checker configuration behavior is unclear to operators (what reads KV vs file, what requires restart), creating operational friction and “edit JSON in KV” workflows.
- Settings → Configuration Management does not currently surface `snmp-checker` (and mapper “LAN discovery” configuration still requires editing raw JSON blobs), which blocks non-expert operators from safely configuring SNMP credentials and discovery jobs.

## What Changes

### 1. Add UI-managed discovery configuration (Network → Discovery)
- Add a “Discovery Configuration” section to the Network → Discovery view.
- Allow admins to configure mapper discovery inputs (seed routers, credential selection, schedule/enable flags as supported by mapper config).
- Reuse the existing admin configuration API and proxy pattern for mapper config:
  - UI calls the web proxy route `GET/PUT /api/admin/config/mapper`
  - Next.js proxies to Core `GET/PUT /api/admin/config/mapper` with `X-API-Key` + bearer auth
  - Core persists to KV (`config/mapper.json`) via the existing config descriptor machinery
- Core remains the authoritative write path; the browser does not write KV directly.

### 2. Add per-interface SNMP metric polling controls
- For interfaces discovered by mapper, allow enabling/disabling SNMP metric polling from the UI (toggle at the interface level).
- Store interface polling preferences in KV and derive effective SNMP polling behavior from it.

### 3. Add Core API surfaces for discovery config + polling preferences
- Mapper config uses the existing Core admin config API surface (`/api/admin/config/mapper`).
- Add new Core endpoints for per-interface SNMP polling preferences with appropriate authZ.
- Add matching Next.js proxy routes so the browser only calls `web/src/app/api/*` routes (consistent with the Settings/Admin UI).
- Ensure reads redact sensitive values (community strings, auth passwords, API keys).

### 4. Make config propagation and “restart required” explicit
- Surface whether changes are live-applied or require restart (current mapper/snmp-checker behavior logs “restart to apply changes” on KV updates).
- UI shows “pending restart” (or similar) when the running service has not yet applied the latest config.

### 5. Make SNMP checker configuration discoverable in Settings → Configuration Management
- Ensure `snmp-checker` (global config descriptor `config/snmp-checker.json`) is visible and editable in the Configuration Management UI.
- Prefer a typed form for common SNMP checker settings (targets, timeouts, credential inputs) with an “Advanced JSON” escape hatch.

### 6. Replace “paste JSON into Details” with service-type-aware forms
- For Poller → Agent checks (poller config), replace free-form `service_type` inputs with a dropdown of supported check kinds.
- Hide the “gRPC catch-all” when possible:
  - If the user selects a known gRPC-backed check (e.g. Sysmon), UI sets `service_type="grpc"` and `service_name="sysmon"` automatically.
  - If the user selects Mapper discovery status, UI sets `service_type="mapper_discovery"` and renders the mapper-specific fields (instead of requiring raw JSON in `details`).
  - Provide an “Advanced / Custom” option to retain the current behavior for power users.

## Implementation Notes (Current State)

### Core API + KV storage
- Per-interface SNMP polling preferences are stored as one KV entry per interface under `prefs/snmp/interface-polling/<device_id>/<if_index>.json`.
- Core exposes admin endpoints to read/update preferences and to rebuild effective SNMP checker targets:
  - `PUT /api/admin/network/discovery/snmp-polling`
  - `POST /api/admin/network/discovery/snmp-polling/batch`
  - `POST /api/admin/network/discovery/snmp-polling/rebuild`
- Core can derive `config/snmp-checker.json` targets from enabled interface preferences (managed targets are prefixed with `ifpref_`).
- Sensitive fields are redacted on `GET /api/admin/config/{service}` for `mapper` and `snmp-checker`, and redacted placeholders are restored on `PUT` so UI edits do not wipe secrets.
- Mapper KV placeholder repair was adjusted to avoid overwriting operator-managed mapper config.

### Web UI
- Network → Discovery includes:
  - “Discovery Configuration” (admin-only) for mapper scheduled job `enabled` + `seeds`
  - Per-interface “SNMP Polling” toggle
  - Propagation state (“Applied” vs “Restart required”) for mapper and snmp-checker based on Core config metadata vs watcher started timestamps
- Settings → Configuration Management MUST surface `mapper` and `snmp-checker` global configs, and MUST provide a service-type-aware editor for poller checks so operators do not need to hand-author JSON in text inputs for common workflows (LAN discovery, SNMP credentials).
  - Mapper now has a typed editor for runtime tuning, default credentials, credential rules, scheduled jobs, UniFi APIs, and stream publishing (with JSON view for advanced fields like OIDs and SNMPv3).

### Local docker-compose testing (no secrets in files)
- Use a gitignored `docker-compose.override.yml` to:
  - pin services to `ghcr.io/carverauto/serviceradar-*:local` images
  - KV-enable `snmp-checker` via environment variables (no secrets required)
- Build/load local images via Bazel `oci_load` targets (e.g. `//docker/images:web_image_amd64_tar`) and recreate services.
- Set secrets at runtime via Core admin config APIs (never check secrets into the repo).

## Impact
- Affected specs: `kv-configuration`, new `network-discovery` capability, new `configuration-management` capability
- Affected code:
  - Core API: endpoints for mapper config and SNMP interface polling preferences
  - KV config write path: `config/mapper.json`, `config/snmp-checker.json` (and/or additional keys per design)
  - Web UI: `web/src/app/network/*` and `web/src/components/Network/*` (Network → Discovery); `web/src/app/admin/*` and `web/src/components/Admin/*` (Configuration Management)
  - KV: additional keys/prefixes for per-interface SNMP polling preferences

## Status
- Implemented for Network → Discovery + per-interface polling + Configuration Management UX (SNMP checker visibility, typed mapper/snmp editors, and check-kind dropdown).
