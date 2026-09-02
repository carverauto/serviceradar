## Context

Armis already returns wired attachment context. ServiceRadar stores it only as device metadata:

- `metadata.armis_access_switch` = `<switch-hostname>:<port>` (examples: `niadcs-bldd03-asw001:gi1/3`, `nordcs-idfltc-asw001:1/1/41`)
- `metadata.armis_vlans` = a JSON array string such as `[561]`

`ocsf_devices.vlan_uid` already exists and is unused. `network_interfaces` is endpoint NIC inventory, not switch attachment. `add-armis-attachment-metadata` explicitly deferred topology-normalization.

OpenText NOM (Network Automation `list device`, optional NNMi) is the next attachment source. Live NNMi `GET /nnmi/api/disco/v1/attachedSwitchPort` is an end-node L2 lookup: query by endpoint MAC (uppercase, no separators) or IP, then follow HAL links for switch hostname (`hostedOn`), port `ifName`, and optional VLAN title. VLAN titles are often names, not numeric IDs. The collection must run against ServiceRadar endpoints (Armis/sweep MAC/IP), not against the HPNA switch list.

Identity disagreement already exists as `SourceIdentityDrift` / `platform.source_identity_conflicts`. Those rows withhold Armis northbound updates. Reusing them for "Armis says gi1/3, NNMi says 3/1/28" would mix fact comparison with identity repair.

Wasm inventory plugins are not `IntegrationSource` rows. Armis is. Winner policy therefore cannot live only on `integration_sources.settings` or only in `plugin.yaml`.

## Goals / Non-Goals

- Goals:
  - One canonical switch-port attachment object and a populated `vlan_uid` on `ocsf_devices`.
  - Preserve source-native metadata keys.
  - Compare facts from any current or future source with the same detector.
  - Let operators choose which source wins, on the catalog of integration sources and plugin assignments, not in plugin manifests.
  - Emit a timeline event and keep a durable report when sources disagree.
  - Backfill from existing Armis metadata; later emit the same facts from optional NNMi L2.
- Non-Goals:
  - Inferring mapper/LLDP topology edges from Armis strings or NNMi HAL links (later).
  - Treating `network_interfaces` as switch attachment.
  - Replacing or extending `source_identity_conflicts` identity categories.
  - Letting a plugin package declare that it is authoritative.
  - Auto-repairing identity merges because attachment disagrees.
  - Making NNMi L2 required for NOM inventory. `nnm_url` omitted means inventory-only.

## Decisions

- Decision: Keep source-prefixed metadata and add canonical fields beside it.
  - Rationale: Operators and existing SRQL already use `metadata.armis_access_switch`. Dropping it would hide provenance. Canonical fields are how NOM, NetBox, and future sources share one query surface.
  - Alternatives: Replace Armis keys with canonical-only storage; rejected because it breaks current queries and loses source-native evidence.

- Decision: Canonical `switch_port_attachment` is JSONB on `ocsf_devices` with a fixed shape, not another metadata key and not a topology edge yet.
  - Shape:
    ```json
    {
      "switch_hostname": "niadcs-bldd03-asw001",
      "switch_device_uid": null,
      "port": "gi1/3",
      "if_alias": null,
      "vlan_id": "561",
      "vlan_name": null,
      "source": "armis",
      "source_instance": "<source-id-or-instance>",
      "observed_at": "<rfc3339>",
      "raw": "niadcs-bldd03-asw001:gi1/3"
    }
    ```
  - `vlan_uid` remains the OCSF scalar for the winning access/native VLAN id when it is numeric or otherwise stable. VLAN *names* from NNMi stay on the attachment object and in source metadata until a VLAN inventory exists.
  - Alternatives: Only topology edges; rejected because the user asked for a device field and SRQL `in:devices` is the current operator surface. Only `metadata.switch_port_attachment`; rejected because it collides with the source-prefix rule and is harder to index than a first-class column.

- Decision: Platform-owned fact keys, recorded per source, compared in core.
  - First keys: `switch_port_attachment`, `vlan_uid`.
  - Each present `device_source_observation` (or equivalent) stores the normalized fact value and a compare hash. Built-in adapters (Armis) and plugins emit the same keys.
  - New sources participate by emitting those keys. Core does not grow an Armis-vs-NNMi special case.
  - Alternatives: Compare raw metadata keys (`armis_access_switch` vs `opentext_nom_access_switch`); rejected because every pair of sources would need a translator. Put facts only on the canonical device; rejected because then the losing source's evidence disappears.

- Decision: Do not reuse `platform.source_identity_conflicts`.
  - Persist `platform.source_fact_disagreements` (name may vary) keyed by canonical device, fact key, and the set of disagreeing sources. Status is `open`, `cleared`, or `dismissed`. These rows are diagnostic, not retention-managed like `ocsf_events`.
  - Also emit an OCSF event on open, material change, and clear so the device timeline shows the conflict. Do not emit a new event on every identical snapshot.
  - The SRQL report reads the diagnostic table, not the 14-day event hypertable.
  - Alternatives: OCSF findings; possible later, but findings are a security model in flight and would bury inventory hygiene. Notification-platform alerts; optional later consumer of the same events.

- Decision: Operator authority lives in a platform catalog, not `plugin.yaml`.
  - Rows identify a source as an `integration_source`, a plugin assignment / inventory instance, or a source-type default (`armis`, `opentext-nom`, `netbox`, ...).
  - Each row names one fact key (or `*` later) and a rank. UI on the integration-source form and the plugin-assignment/credential-rule form exposes "When sources disagree, this source wins for: Switch port / VLAN".
  - Plugin manifests MUST NOT contain winner, precedence, or authority fields. They MAY optionally list `emitted_facts` as a capability advertisement; core also infers keys from observed facts so advertisement is not required for disagreement to work.
  - Default with no authority configured:
    1. One source reports the fact: promote it.
    2. Multiple sources agree after normalization: promote it and attribute the highest-ranked reporting source, else the earliest configured source.
    3. Multiple sources disagree: leave canonical unchanged (null if never set), open a disagreement, emit an event. Do not clobber a previously promoted value.
    4. Exactly one configured authority for that fact: promote that source's value, keep the disagreement visible so operators still see the other source.
    5. Two or more authorities for the same fact: treat as a configuration conflict, do not change canonical, open the disagreement with a configuration marker.
  - Absent observations drop out of the comparison. When only one remaining present source reports the fact, the disagreement clears and canonical follows the remaining source unless an operator dismissed it with a pin (out of scope for v1).
  - Alternatives: Recency always wins; rejected because Armis and NNMi cadences differ and would flap. Plugin.yaml `authoritative: true`; rejected by the user. Armis-hardcoded winner; rejected because NOM is the L2 specialist.

- Decision: Normalize before compare, store both raw and normalized.
  - Switch hostname: trim, case-insensitive. Do not strip DNS suffixes unless both values share a suffix (v1 compares the hostname as stored).
  - Port: trim, case-insensitive (`gi1/3` == `Gi1/3`). Do not strip media prefixes (`gi` vs `1/3`); that can collide.
  - Armis parser: split `armis_access_switch` on the last colon into hostname and port.
  - VLAN: parse `armis_vlans` JSON/array/scalar; canonical `vlan_uid` is the single access VLAN when one numeric id is present. Extra VLANs stay in source metadata.
  - NNMi VLAN titles that are not ids populate `vlan_name` only.

- Decision: Optional NNMi L2 is a second pass in the OpenText NOM plugin after NA inventory, against ServiceRadar endpoints.
  - NA `list device` remains the switch/router inventory snapshot.
  - When `nnm_url` is set, a later collection (same plugin or a follow-on action) looks up attached switch ports for endpoint MAC/IP already in ServiceRadar. It does not iterate HPNA switch IPs.
  - Results attach to the *endpoint* device as `opentext-nom` facts, with `switch_hostname` that DIRE can later join to the NA-imported switch.
  - Empty NNMi `items` is "no L2 match", not a failure.
  - This pass is blocked on the canonical fact pipeline so NNMi does not invent a third metadata-only field.

## Risks / Trade-offs

- Hostname:port parsing is tenant-specific. Mitigation: last-colon split plus raw passthrough; do not guess port speed prefixes.
- NNMi VLAN names will not fill `vlan_uid`. Mitigation: attachment.vlan_name plus disagreement only when both sides have comparable ids.
- Authority on two catalogs (integration sources vs plugin assignments) can drift. Mitigation: one `source_fact_authorities` table with typed refs and a single settings UI pattern.
- Event volume. Mitigation: emit on state change only; diagnostics are upserted.
- Canonical JSONB plus source metadata duplicates bytes. Mitigation: attachment objects are small; metadata keys are the audit trail.

## Migration Plan

1. Add nullable `switch_port_attachment` and the fact/disagreement/authority tables. Do not change Armis metadata writers.
2. Parse existing `armis_access_switch` / `armis_vlans` into per-source facts and promote where no conflict exists (the current Daktronics-style rows).
3. Ship operator authority controls. Default remains conservative (no silent clobber).
4. Enable disagreement events and the SRQL report.
5. Add the optional NOM NNMi L2 pass against endpoint MAC/IP.

Rollback drops unread canonical columns and stops the detector; source metadata remains.

## Open Questions

- Should a resolved switch hostname also populate `switch_device_uid` in v1 when DIRE can match the NA-imported switch, or leave that for the later topology pass?
- Should dismissed disagreements pin the current canonical value against future promotions from the losing source?
