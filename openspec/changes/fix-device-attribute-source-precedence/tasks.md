## 1. Recorded strength for single-valued attributes

- [ ] 1.1 Store source and evidence strength alongside `name`, `vendor_name`,
      `type`, `integration_type` and `management_device_id`, so a recorded
      clear is distinguishable from an unset value; a populated value with no recorded
      strength is kept against weakest-tier writes; the next write of any
      tier above the weakest replaces it and records its strength
- [ ] 1.2 Upsert: record the source with the strength; a write replaces the
      recorded value when strictly stronger, or equal and from the same
      source; a different source at the same tier keeps the stored value; a
      weaker value fills only an attribute with no recorded strength (a
      recorded clear is a stored decision)
- [ ] 1.3 Batch merge (`merge_records_by_uid`): same order, same rule
- [ ] 1.4 Derive an address fallback name from the address kept after the
      address rank guard
- [ ] 1.5 An address-fallback write carries the kept address in both `name`
      and `hostname`

## 2. Name precedence

- [ ] 2.1 Writers tag names: address fallback (passive census or hypervisor
      enrichment without a hostname) < passive census sighting with an
      observed hostname < automation inventory (AWX) name < SNMP `sysName` <
      platform inventory name (hypervisor, camera or other decision 13
      inventory); `hostname` is gated by the same
      tiers and accepted or rejected together with `name`;
      `HypervisorEnrichmentIngestor`'s repeating existing-device host and
      guest update and `placeholder_device_update` (create path) carry the
      inventory record's name as the strongest-tier name / hostname pair when
      the record has one (a `provider_ref` or an address is never that name;
      an update with no record name stays address fallback)
- [ ] 2.2 Test: a `sysName` survives a hostname-less census update, in one
      batch and across batches
- [ ] 2.3 Test: a hostname-less sighting of a rejected address, including an
      NDP / `fe80::` sighting, does not rename the device
- [ ] 2.4 Test: a hypervisor-enrichment update without a hostname keeps the
      node name reported by the automation inventory
- [ ] 2.5 Test: on a hypervisor node, alternating automation-inventory, mapper
      `sysName` and hypervisor-inventory writes leave `name` and `hostname` at
      the hypervisor inventory value in either batch order, and Proxmox plugin
      assignment inputs do not change
- [ ] 2.6 Test: a hypervisor placeholder with no record name records the
      address fallback, not the `provider_ref`, and a later `sysName`
      replaces it

## 3. Vendor precedence

- [ ] 3.1 Writers tag vendors: a name naming agent software (device,
      integration or metadata evidence) < IEEE OUI lookup result (always this
      tier, whatever the registrant string) < hardware vendor name (device,
      integration or metadata evidence: `sysObjectID` hardware enterprise,
      `sysDescr`, a classification rule including under enterprise 8072, an
      integration report, or explicit metadata); a weakest-tier
      vendor never replaces a populated value without recorded strength or any
      stronger value; provenance keys follow the kept value
- [ ] 3.2 Keep the agent-software enterprise list (Net-SNMP 8072 and similar)
      next to the enterprise-to-vendor table, only to mark table entries whose
      name is agent software
- [ ] 3.3 Stop writing OS, software or platform names to `vendor_name` from
      any source (fingerprint, classification rule, integration, metadata);
      write OS / software names to the OS / software fields, and still rank
      the same update's OUI or hardware vendor
- [ ] 3.4 Test: a hardware-enterprise vendor with recorded strength survives
      an OUI update; an OUI vendor survives an update whose derived vendor
      names agent software (Net-SNMP); a hardware vendor from `sysDescr` or a
      classification rule replaces the OUI vendor even when the `sysObjectID`
      is under enterprise 8072; OUI replaces OUI
- [ ] 3.5 Test: a `sysDescr`-inferred hardware vendor with recorded strength
      survives an OUI-only update
- [ ] 3.6 Test: a fingerprint classification naming an OS leaves
      `vendor_name` unchanged; an automation inventory reporting its own
      platform name leaves `vendor_name` and `model` unchanged; Proxmox
      discovery's `Proxmox` / `PVE` leaves a recorded SNMP vendor and model
      unchanged; an OS fingerprint leaves `model` unchanged; a metadata `Net-SNMP`
      leaves an OUI vendor in place and a metadata hardware vendor replaces it;
      an update classifying Linux with an OUI fills an empty vendor with the
      OUI; a census OUI `Ubiquiti Inc` leaves a recorded `sysObjectID`
      `Ubiquiti` in place

## 4. Type and integration type precedence

- [ ] 4.1 Writers tag `type`: generic `host` / default < fingerprint or
      classification-rule type < SNMP-derived type < platform-inventory type;
      `type`, `type_id` and `metadata.device_role` are accepted or rejected
      together (mapper `persist_role_metadata` included); manual ownership
      keeps precedence over all three
- [ ] 4.2 Writers tag `integration_type`: generic automation inventory <
      platform inventory that discovers the device as its own object
- [ ] 4.3 Test: alternating automation-inventory and hypervisor writes leave
      `type` and `integration_type` at the hypervisor values; a mapper
      `ip_forwarding` update leaves a hypervisor node's type `Hypervisor` and
      its `type_id` unchanged; a mapper pass scoring a hypervisor node as
      `host` leaves `device_role` `hypervisor`, `target_kind` `pve_host`, and
      the Proxmox assignment inputs unchanged

## 5. Integration identifiers and plugin inputs

- [ ] 5.1 Drop the metadata `integration_id` slot from the upsert and move its
      readers to the provider-scoped identifiers in `device_identifiers`:
      `IdentityProjections.binding_keys` (unmerge), `ArmisNorthboundPopulation`,
      and the `SourceIdentityDrift` repair reread; stop the `ResultProcessor`
      writer that copies a snapshot `integration_id` into update metadata, or
      move it to the provider-scoped identifier
- [ ] 5.2 `PluginInputPayloadBuilder.normalize_device_row`: copy an
      integration identifier only into input items for the plugin whose
      provider owns it
- [ ] 5.3 Proxmox inputs and `ProxmoxHostAuthority.target_ids` read the
      hypervisor provider ref from `device_identifiers`
- [ ] 5.4 Test: alternating automation-inventory and hypervisor writes leave
      Proxmox plugin assignment inputs unchanged

## 6. Attribute ownership

- [ ] 6.1 Accept or reject `model` together with `vendor_name`
- [ ] 6.2 Owned metadata keys (design.md decision 12) are replaced only by
      their owner; other ingestors (for example the automation inventory's
      `proxmox_node`) only fill an absent key
- [ ] 6.3 Rank `management_device_id`: platform inventory (camera) > mapper;
      a platform clear to none is the stronger value, and the mapper's
      empty-fill does not put a parent back on a device whose platform
      inventory cleared it
- [ ] 6.4 Test: for every attribute in the decision 12 table, drive the real
      writers (the sync upsert, the mapper results ingestor, the camera
      inventory ingestor and the other decision 13 writers) with a non-owner
      or weaker write after an owner or stronger write and assert the stored
      value is unchanged, and with a fill into an absent value and assert it
      is stored; include a camera clear to none followed by a mapper pass
- [ ] 6.5 Route every decision 13 platform-inventory writer
      (`HypervisorEnrichmentIngestor`, `ProxmoxEnrichmentIngestor`,
      `Camera.InventoryIngestor` `camera_device_update_attrs`, WiFi-map
      controller / batch ingestion, `EndpointInventoryIngestor`) through the
      shared strength decision; remove direct updates that skip it; stop
      `AgentGatewaySync` writing `name`, `hostname`, `type`, `type_id` or
      `device_role`; stop defaulted vendors (for example the WiFi-map batch
      filler) writing `vendor_name`
- [ ] 6.6 Apply a multi-field value as a whole: fields a write does not carry
      stay stored (a role-only write keeps `type` / `type_id`; a vendor
      without a model keeps `model`)
- [ ] 6.7 Test: an SNMP-polled camera keeps the camera inventory name,
      vendor, model, type and `management_device_id` (including a recorded
      clear) across mapper and census passes; a same-tier
      mapper hardware vendor keeps the first recorded camera vendor; an agent
      check-in leaves a guest's type and name unchanged; a defaulted WiFi-map
      vendor does not write `vendor_name`; and the agent
      config version does not change

## 7. Primary address and aliases

- [ ] 7.1 Upsert guard in `DeviceWrites`: IPv4 always preferred when the
      device has a usable, chooser-accepted IPv4; IPv6 only on IPv6-only
      devices; the preference ranks only addresses a chooser accepts; IPv4 to IPv4
      re-IP replaces; the #3905 rank applies within a family
- [ ] 7.2 `Identity.Address.best/1` and its rank follow the same rule; extend
      the existing SQL / Elixir rank parity test to the family rule
- [ ] 7.3 Hypervisor guest primary-IP NIC selection (`primary_ip_by_guest`)
      and the camera and succession primary-IP paths follow the same rule;
      `GuestAddress.primary/1` keeps skipping host-internal addresses (for
      example a docker bridge), and no chooser promotes an address it rejects
- [ ] 7.4 Hypervisor host selection (`primary_ip_by_host/1`,
      `primary_interface_ip`, `management_ip_score`,
      `routable_management_ip?`) and the `DeviceDiscoveryIngestor` guest
      address fallback submit the best chooser-accepted IPv4 among every
      address on the host or guest, prefer it over any IPv6, and never submit
      a link-local (`fe80::/10`, `169.254/16`) as primary
- [ ] 7.5 Proxmox plugin `primaryIP` / `firstUsableIP`
      (`go/cmd/wasm-plugins/proxmox/summaries.go`, called from
      `discovery.go`), Armis `primaryIP`
      (`go/pkg/agent/syncsources/armis/device.go`, called from `update.go`)
      and the succession hand-over `MergeEngine.take_address?/2` prefer a
      chooser-accepted IPv4 over any IPv6 and never submit a link-local;
      keep each chooser's own order among accepted IPv4s; keep NetBox
      `primaryIP`'s existing IPv4-first behaviour and IPv6 fallback
- [ ] 7.6 Find any other primary-IP chooser, apply the same rule, and cover
      each one with the extended parity test
- [ ] 7.7 Census decoder: an NDP / IPv6 sighting of a device with a usable
      IPv4 records an aliasable IPv6 as an alias and does not set the primary
      `ip`; a link-local sighting is neither alias, primary nor name
- [ ] 7.8 Alias recording: every aliasable address the device owns, in both
      families, stays a live `device_alias_states` row, including a displaced
      or never-promoted address; aliasable means `AliasPolicy.valid_alias_ip?/1`
      accepts it (link-local and directed broadcasts are rejected) and it is
      not host-internal (`GuestAddress.host_internal_address?/2`, the Proxmox
      plugin's host-internal set, or a shared interface address `AliasEvents`
      keeps off the `:ip` merge type)
- [ ] 7.9 Alias expiry: a confirmed re-attribution expires the previous
      holder's alias in the same write; a holder that has not re-sighted an
      address within the alias expiry window is expired
- [ ] 7.10 `SweepCompiler` attributes each target only to the current live
      holder
- [ ] 7.11 Test: dual-stack census keeps the IPv4 primary and records the
      global IPv6 as a live alias with a non-IPv6 name; a link-local
      sighting records no alias, primary or name; a guest's `172.17.0.1` on
      `docker0` never becomes primary or an alias; a directed broadcast is
      never an alias; an IPv6-only device that
      gains an IPv4 switches primary; an IPv4 re-IP replaces; two compiles of
      an unchanged inventory produce identical sweep targets and
      `device_uid` attribution; a stale cross-device alias is expired on
      confirmed re-attribution

## 8. Rollout

- [ ] 8.1 Release note: credential rules keyed on an exact OUI vendor string
      stop matching any device with a recorded hardware vendor whose spelling
      differs; the settled spelling comes from the first source recorded at
      the hardware tier, SNMP (hardware `sysObjectID` enterprise, or a
      hardware vendor from `sysDescr` or a classification rule even when the
      `sysObjectID` is under enterprise 8072) or a platform inventory such as
      the camera inventory, and on pre-rollout rows from the first
      hardware-tier writer after the census OUI pass; the OUI spelling
      remains for every device with no recorded hardware-tier vendor,
      including devices whose only vendor evidence is the OUI and devices
      whose other evidence names agent software or an OS / software product;
      legacy rows
      whose stored vendor was agent software, an OS or a software product
      start matching once the first census pass records the OUI vendor; rules
      keyed on fingerprint OS / software names in `vendor_name` must move to
      the OS / software fields
- [ ] 8.2 Verify on a deployment with existing inventory: config version of an
      affected agent changes at most once per strictly stronger tier first
      recorded for each attribute (name / hostname, `vendor_name` / `model`,
      `type` / `type_id` / `device_role`, `integration_type`,
      `management_device_id` including a recorded clear), then stays
      constant across further
      census passes, mapper runs, automation-inventory cycles and
      hypervisor-enrichment cycles. Example name ladder on a hypervisor node:
      census hostname, then AWX name, then mapper `sysName`, then hypervisor
      inventory name. Example type ladder: fingerprint, then SNMP, then
      platform. A hostname-less census name is the address fallback and never
      replaces a populated name without recorded strength or any stronger
      name
- [ ] 8.3 Verify on a deployment: an affected agent's sweep config version
      stays constant across census passes, and dual-stack devices keep an
      IPv4 primary
