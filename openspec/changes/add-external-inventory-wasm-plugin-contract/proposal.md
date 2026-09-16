# Change: Add a package-declared inventory Wasm plugin contract

## Why
ServiceRadar needs many edge inventory integrations. Core must not gain a provider module, static catalog entry, dedicated workflow, provider documentation, or provider-specific tests every time one is added.

The signed Wasm package is the correct ownership boundary. It can carry its provider identity, JSON configuration schema, credential profile, producer schedule binding, inventory-source display metadata, and operator documentation while core supplies generic validation, scheduling, credential brokering, durable record transport, DIRE reconciliation, persistence, and read APIs. Inventory output is a potentially long record stream, not one whole-run plugin result.

OpenText Network Operations Management (NOM) is the first implementation of this contract. It is maintained as a first-party plugin in the ServiceRadar tree, but its signed package remains the runtime ownership boundary. Its current inventory export is manual, so an edge plugin will collect a bounded switch inventory once per day and on demand. Canonical switch-port attachment, VLAN promotion, and cross-source fact disagreement live in `add-canonical-device-facts-and-source-disagreement`; this change does not bury those rules in the plugin manifest.

## What Changes
- Add a validated `integrations` descriptor to signed Wasm manifests for package-owned documentation, credential profiles, producer-schedule bindings, inventory sources, and source metadata fields.
- Build a runtime integration catalog exclusively from approved package descriptors and reject duplicate claims without reserving provider names in core.
- Replace provider-specific credential provisioners and UI branches with generic package-driven configuration, assignment, schedule, Run Now, and source-provenance behavior.
- Accept bounded typed inventory pages plus a terminal manifest from any valid discovery source through the agent-owned durable producer sink. Stage pages incrementally and atomically activate a new source snapshot only after its completeness proof validates; persist bounded nested `source_metadata`, and require source plus instance on the cursor-paginated source-inventory API.
- Keep provider-specific protocol code, configuration schema, documentation, display metadata, fixtures, and tests inside the plugin package directory rather than core runtime modules or global provider catalogs.
- Provide one protected external-plugin release workflow parameterized by repository and tag. It packages conventional `docs/`, `display/`, and `schemas/` resources without executing external repository scripts in the signing job.
- Build the first Go/TinyGo plugin in `go/cmd/wasm-plugins/opentext-nom` and publish it through the existing generic first-party Wasm workflow. It executes a fixed bounded `list device` operation, uses brokered credentials, streams assignment-approved binary inventory pages and a terminal manifest, and never writes ServiceRadar storage or selects a broker route directly.
- Provide a source-native local development host in both ServiceRadar SDKs so plugin authors can exercise normal config, action invocation, result, logging, and host-HTTP contracts without first building, signing, publishing, or deploying a Wasm package.
- Reconcile external observations through DIRE using stable source integration identifiers and existing guarded hardware evidence while preserving every discovery source.

## Impact
- Affected specs: `external-inventory-plugin`, `wasm-plugin-system`, `device-identity-reconciliation`, `device-inventory`, `plugin-configuration-ui`
- Affected code: first-party and external inventory plugin packages; first-party Wasm build inventory; package manifest/import validation; generic credential reconciliation; producer schedules and action-result ingestion; device source observations; DIRE; source-inventory API; web-ng credentials and provenance UI; protected Forgejo workflows
- Related changes: `unify-sweep-results-proto`, `fix-endpoint-inventory-profile-operations`, `add-proxmox-plugin-credential-rules`, `fix-plugin-credential-provisioning-ux`, `refactor-unified-credential-management`, `unify-plugin-credential-rules-db-surface`, `refactor-device-identity-reconciliation`, `harden-source-authoritative-device-identity`, and `show-all-device-integrations-and-hierarchy`
- Linked NCO change: `source-nac-opentext-network-automation-inventory-from-serviceradar`
- **BREAKING**: pre-release external inventory packages that emit a whole snapshot through `serviceradar.plugin_result.v1` must be rebuilt for the durable binary inventory-page ABI. Existing bounded health/check status remains compatible, and deployed agents are upgraded as one supported cohort before this output contract is enabled.
