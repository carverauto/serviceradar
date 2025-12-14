# Change: Configure mapper discovery + SNMP polling via UI

## Why
- `serviceradar-mapper` and `serviceradar-snmp-checker` are configured via JSON files and KV-backed config keys, but there is no first-class UI workflow for managing discovery seeds or SNMP polling behavior.
- The Network → Discovery UI surfaces discovered devices/interfaces, but it is effectively read-only; operators cannot steer discovery (seed routers) or selectively enable/disable SNMP interface metric polling.
- Mapper and SNMP checker configuration behavior is unclear to operators (what reads KV vs file, what requires restart), creating operational friction and “edit JSON in KV” workflows.

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

## Impact
- Affected specs: `kv-configuration`, new `network-discovery` capability
- Affected code:
  - Core API: endpoints for mapper config and SNMP interface polling preferences
  - KV config write path: `config/mapper.json`, `config/snmp-checker.json` (and/or additional keys per design)
  - Web UI: `web/src/app/network/*` and `web/src/components/Network/*` (Network → Discovery)
  - KV: additional keys/prefixes for per-interface SNMP polling preferences

## Status
- Feature request / planning: create proposal, align on storage model + propagation semantics, then implement behind admin-only UI.
