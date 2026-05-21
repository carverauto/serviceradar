# Change: Add service-oriented plugin monitoring

## Why
ServiceRadar's plugin checks are still too configuration-centric: an operator often has to define all targets inside a plugin assignment before the plugin is useful. That works for a small hand-built config, but it breaks down for normal monitoring operations where users need to monitor hundreds of websites, databases, or device services using the plugins already loaded on agents.

Operators need a workflow closer to Checkmk, Zabbix, Nagios, and WhatsUp Gold: select devices or services from inventory, choose what to monitor from loaded plugin capabilities, apply credentials from reusable rules or explicit overrides, and decide how check state becomes events and alerts.

## What Changes
- Add first-class service targets that may be associated with devices or may stand alone for URLs, APIs, SaaS endpoints, and external databases.
- Add monitoring bindings that connect plugin-declared check capabilities to device/service target sets, schedules, threshold profiles, credential policies, and event/alert promotion rules.
- Extend plugin package manifests with reusable check descriptors so plugins expose "HTTP URL check", "PostgreSQL availability", "TLS certificate expiry", etc. rather than forcing operators into raw plugin params.
- Compile monitoring bindings into agent plugin assignments with concrete target batches, credential broker grants, allowlists, and stable service/check identities.
- Support bulk creation/import for large URL/database/service sets and SRQL/tag-driven target selection for inventory devices.
- Reuse unified credential management for network-wide credential rules and per-device or per-service credential overrides.
- Update the plugin configuration UI to prefer searchable selectors and bulk workflows over free-form device/service text fields.
- Add service availability dashboards built with the dashboard SDK and driven by SRQL queries over tags, services, checks, and plugin capability metadata.
- Define check-result normalization so status changes can create events, and event/rule state can promote to alerts with dedupe, cooldown, severity, and ownership metadata.
- Update Go and Rust plugin SDKs in parity so plugin authors can declare check descriptors, consume normalized target contexts, request brokered credentials, and emit target-scoped results.

## Impact
- Affected specs:
  - `service-monitoring` (new)
  - `wasm-plugin-system`
  - `plugin-configuration-ui`
  - `plugin-sdk-go`
  - `plugin-sdk-rust` (new unless already introduced by another active change)
  - `srql`
  - `observability-signals`
  - `build-web-ui`
  - `dashboard-sdk` (new unless already introduced by another active change)
- Related active changes:
  - `add-external-secret-provider-broker` should define the credential-provider and broker abstraction used by service monitoring bindings.
  - `refactor-unified-credential-management` should remain the credential UX foundation.
  - `add-proxmox-plugin-credential-rules` provides the existing brokered credential-rule model to generalize.
  - `add-northbound-action-integrations` provides descriptor and target-context patterns for plugin-exposed actions.
  - `add-per-agent-availability` provides per-agent availability state semantics that service checks should align with.
- Affected code:
  - Ash resources and migrations for services, service groups, monitoring bindings, check instances, result state, and escalation policy links.
  - Plugin package import/approval, assignment materialization, agent config, and plugin result ingestion.
  - Go agent plugin runtime and target-batched execution.
  - Go SDK at `~/src/serviceradar-sdk-go` and Rust SDK at `~/src/serviceradar-sdk-rust`.
  - Web-ng service inventory, device details monitoring tab, settings credentials linkage, searchable target pickers, bulk import flows, and dashboard package integration.
  - SRQL service/check entities, rollups, tag filters, and dashboard query support.
  - Dashboard source created through the dashboard SDK repository if the dashboard SDK repo is present in the developer workspace.

## Non-Goals
- Do not let plugins run arbitrary UI, arbitrary SQL/SRQL, or arbitrary raw target strings supplied by the browser.
- Do not duplicate devices just to represent per-service monitoring.
- Do not move credential plaintext into plugin params, browser payloads, result details, logs, or assignment JSON.
- Do not require every website URL to be represented as a device.
- Do not replace existing ICMP/TCP sweep paths; integrate them as built-in availability capabilities where useful.
- Do not implement every service type in the first PR. HTTP/S, TCP, TLS, and one database capability are enough to prove the model.
