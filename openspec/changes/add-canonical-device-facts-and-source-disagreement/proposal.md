# Change: Canonical device facts and generic source disagreement

## Why

Switch-port and VLAN evidence already exists in ServiceRadar, but it is trapped in source-prefixed metadata. Live inventory stores Armis attachment as `metadata.armis_access_switch` in `<switch-hostname>:<port>` form, with VLANs in `metadata.armis_vlans`. Operators can find that with `in:devices metadata.armis_access_switch:"%:%"`, but there is no canonical device field, `ocsf_devices.vlan_uid` is unused, and a second source such as OpenText NOM / NNMi has nowhere generic to write the same fact.

`add-armis-attachment-metadata` intentionally kept those values as `armis_*` metadata until a later normalization change. That later change is this one. Source-identity drift (`platform.source_identity_conflicts`) is the wrong home: it is Armis-northbound identity diagnostics, not comparable inventory facts.

When Armis and NNMi disagree about the access switch, port, or VLAN of the same endpoint, operators need an event and a durable report. The same machinery must work for any current or future integration, and the operator must be able to say which source wins without burying that policy in a plugin manifest.

## What Changes

- Keep source-prefixed metadata as the source-native record. Armis continues to persist `metadata.armis_access_switch`, `metadata.armis_vlans`, and related `armis_*` keys. OpenText NOM may persist `opentext_nom_*` keys the same way.
- Add a canonical `switch_port_attachment` JSONB field on `ocsf_devices` and populate existing `vlan_uid` from the winning source fact.
- Record per-source normalized facts for a small platform-owned fact vocabulary (`switch_port_attachment`, `vlan_uid`, and later additions) so new integrations participate without core provider modules.
- Detect disagreement generically across any sources that report the same fact on the same canonical device. Persist open disagreements, emit an OCSF event on open/change/clear, and expose a SRQL-backed report.
- Let operators set which integration source wins for which fact on the integration-source / plugin-assignment catalog, plus an optional source-type ranking. Plugin packages MAY advertise which facts they emit. Plugin packages MUST NOT declare that they win.
- Promote existing Armis attachment metadata into canonical facts and backfill current rows such as the Daktronics kiosks already carrying `niadcs-bldd03-asw001:gi1/3` and VLAN `561`.
- After the canonical fact pipeline exists, add the optional OpenText NOM NNMi attached-switch-port pass: query NNMi for ServiceRadar endpoint MAC/IP (not HPNA switch inventory), skip the pass when `nnm_url` is omitted, and emit the same generic facts.

## Impact

- Affected specs: `device-inventory`, `source-fact-reconciliation` (new), `sync-service-integrations`, `external-inventory-plugin`, `plugin-configuration-ui`, `srql`
- Affected code: Elixir device schema/migrations and DIRE upsert; device source observations; Armis sync mapping; discovery ingestor; web-ng integration-source and plugin-assignment settings; SRQL device/report fields; first-party OpenText NOM plugin for the later NNMi L2 pass
- Related changes: `add-armis-attachment-metadata` (source-native keys stay), `add-external-inventory-wasm-plugin-contract` (plugin identity is `opentext-nom`; this change owns canonical facts and disagreement), `harden-source-authoritative-device-identity` (identity drift stays separate)
- **BREAKING**: none. New columns are nullable. Source-prefixed metadata remains. Identity-conflict tables are not reused or redefined.
