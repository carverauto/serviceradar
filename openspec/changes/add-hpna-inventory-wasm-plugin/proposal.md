# Change: Add HPNA inventory collection through an edge Wasm plugin

## Why
HPNA switch inventory is currently exported by hand and copied between tools. ServiceRadar should collect that inventory at the edge, reconcile it through DIRE with devices already discovered by Armis or other integrations, and expose one current searchable inventory for NCO and operators.

ServiceRadar already has signed Wasm packages, host-mediated HTTP, credential rules, package-declared producer schedules, the agent command bus, and `serviceradar.device_discovery.v1` ingestion. The missing work is the HPNA package, its credential/configuration profile, action-result ingestion, and conflict-safe cross-source identity/provenance behavior.

## What Changes
- Create the Go/TinyGo HPNA inventory plugin in the separate `serviceradar-plugin-hpna` repository using `serviceradar-sdk-go`; the plugin never writes CNPG directly.
- Add an HPNA plugin configuration schema with bounded `list device` query parameter sets. The default query passes `type=Switch`, while operators may configure an allowlisted subset of HPNA list filters.
- Add an HPNA username/password credential-rule profile and a host-side form-credential injection mode for the HPNA OAuth token exchange. Long-lived credentials remain outside Wasm memory and command/config payloads.
- Declare a once-daily producer schedule and dispatch both scheduled and operator-initiated runs through `plugin.run_action` on the existing agent command bus.
- Add a generic, approved-package result disposition that forwards an inventory-producing action result into normal plugin-result ingestion while returning only bounded command status.
- Emit complete bounded `serviceradar.device_discovery.v1` snapshots and reconcile them through DIRE.
- Add guarded manufacturer-scoped hardware-serial identity so HPNA devices converge with an existing Armis or other canonical device when strong evidence matches. Weak IP/hostname evidence cannot override conflicting strong identities.
- Preserve `hpna` alongside existing discovery sources and source-specific metadata instead of replacing Armis provenance. Track current HPNA source observations, snapshot freshness, and source-object identity.
- Expose authenticated, paginated ServiceRadar inventory reads suitable for NCO, plus SRQL/UI search for HPNA-discovered devices and collection freshness.
- Package, sign, assign, and deploy the plugin to the selected k8s agent in `example-namespace`, then enable its daily schedule.

## Impact
- Affected specs: `hpna-inventory-plugin`, `wasm-plugin-system`, `device-identity-reconciliation`, `device-inventory`, `plugin-configuration-ui`
- Affected code: external `serviceradar-plugin-hpna`; `serviceradar-sdk-go`; agent Wasm action and credential-broker runtime; core plugin schedule/result ingestion; DIRE identifier handling; device source observations; web-ng settings, API, SRQL, and device provenance UI; Helm deployment configuration
- Related changes: `fix-endpoint-inventory-profile-operations` (generic producer schedules), `add-proxmox-plugin-credential-rules`, `fix-plugin-credential-provisioning-ux`, `refactor-unified-credential-management`, `unify-plugin-credential-rules-db-surface`, `refactor-device-identity-reconciliation`, `harden-source-authoritative-device-identity`, and `show-all-device-integrations-and-hierarchy`
- Linked NCO change: `source-nac-hpna-inventory-from-serviceradar`
- **BREAKING**: none. Existing integrations and manually managed devices remain valid; HPNA collection is additive and disabled until an assignment, credential rule, and schedule are enabled.
