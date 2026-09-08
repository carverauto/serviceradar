## 1. Spec and contract
- [x] 1.1 Add OpenSpec deltas for canonical attachment/VLAN fields, generic source-fact disagreement, operator authority, and SRQL report surfaces.
- [x] 1.2 Document that plugin manifests MUST NOT declare fact winners and that `source_identity_conflicts` remains identity-only.
- [x] 1.3 Validate the change with `openspec validate add-canonical-device-facts-and-source-disagreement --strict`.

## 2. Canonical device fields
- [x] 2.1 Add nullable `switch_port_attachment` JSONB to `platform.ocsf_devices` via an Elixir migration (prefix `platform`) and expose it on the Device Ash resource, API, and OCSF export.
- [x] 2.2 Populate existing `vlan_uid` from the winning VLAN fact; do not invent a second VLAN column.
- [x] 2.3 Keep source-prefixed metadata keys (`armis_access_switch`, `armis_vlans`, future `opentext_nom_*`) unchanged on write.
- [x] 2.4 Teach DIRE device upserts to set canonical attachment/VLAN only through the fact-promotion path, not by last-writer metadata merge.

## 3. Per-source facts
- [x] 3.1 Persist normalized per-source facts for platform keys `switch_port_attachment` and `vlan_uid`, keyed by canonical device, source, and source instance.
- [x] 3.2 Parse Armis `metadata.armis_access_switch` (`<hostname>:<port>`, last colon) and `metadata.armis_vlans` into those facts without removing the metadata keys.
- [x] 3.3 Accept plugin discovery `facts` (first-class SDK field, with a documented fallback) into the same table; unknown keys are ignored.
- [x] 3.4 Normalize compare keys (trim, case-insensitive hostname/port; VLAN id string) and store raw plus normalized values.

## 4. Disagreement events and report
- [x] 4.1 Add a durable `platform.source_fact_disagreements` diagnostic table (open/cleared/dismissed) that is not retention-managed like `ocsf_events`.
- [x] 4.2 Open, update, or clear disagreements when present sources disagree, agree, or drop out; do not write a new row on identical snapshots.
- [x] 4.3 Emit an OCSF event only when a disagreement opens, its compared values change, or it clears.
- [x] 4.4 Do not record attachment/VLAN disagreements in `source_identity_conflicts` or withhold Armis northbound updates because of them.

## 5. Operator authority
- [x] 5.1 Add a platform authority catalog keyed by integration source, plugin assignment/instance, or source type, plus fact key and rank.
- [x] 5.2 Expose "this source wins for Switch port / VLAN" on integration-source settings and on plugin-assignment/credential-rule settings. Do not put winner policy in `plugin.yaml`.
- [x] 5.3 Apply the default promotion rules: single source or agreement promotes; disagreement does not clobber canonical unless exactly one authority is set; multiple authorities are a configuration conflict.
- [x] 5.4 Reject or ignore plugin-manifest keys that claim precedence, authority, or winners.

## 6. SRQL and operator report
- [x] 6.1 Index `switch_port_attachment` for SRQL (including nested `switch_hostname` / `port`) and keep `vlan_uid` queryable.
- [x] 6.2 Add a SRQL-backed disagreement report (`in:source_fact_disagreements` or equivalent) with device, fact key, sources, values, status, and authority.
- [x] 6.3 Preserve existing queries such as `in:devices metadata.armis_access_switch:"%:%"`.

## 7. Backfill existing Armis attachment
- [x] 7.1 Backfill facts and canonical fields for devices that already have `metadata.armis_access_switch` and/or `metadata.armis_vlans`, including the Daktronics kiosk set already in inventory.
- [x] 7.2 Re-query after the backfill job and fail the task if canonical fields are empty on those rows while metadata still has attachment values.

## 8. Optional OpenText NOM NNMi L2 pass
- [x] 8.1 Keep NA `list device` as the inventory snapshot; do not look up attached switch ports by HPNA switch IP/hostname.
- [x] 8.2 When `nnm_url` is configured, look up attached switch ports for ServiceRadar endpoint MAC/IP (uppercase, no-separator MAC; comma-batched IPs).
- [x] 8.3 Skip the L2 pass entirely when `nnm_url` is omitted.
- [x] 8.4 Emit `opentext-nom` facts (and optional `opentext_nom_*` metadata) on the endpoint device; treat empty NNMi `items` as no match.
- [x] 8.5 Do not add provider-specific disagreement code; NOM facts MUST flow through the generic detector.

## 9. Verification
- [x] 9.1 Unit-test Armis parsing, promotion, authority, and disagreement open/clear.
- [x] 9.2 Unit-test plugin fact ingestion and rejection of manifest winner claims.
- [x] 9.3 Run focused Go tests for `go/cmd/wasm-plugins/opentext-nom` after any L2-pass code lands.
- [x] 9.4 Run OpenSpec validation, formatting, and the Elixir inventory tests that cover device records and discovery ingestion.
