## 1. Recorded strength for single-valued attributes

- [ ] 1.1 Store source and evidence strength alongside `name`, `vendor_name`,
      `type` and `integration_type`; a populated value with no recorded
      strength is kept against weakest-tier writes; the next write of any
      tier above the weakest replaces it and records its strength
- [ ] 1.2 Upsert: an equal-or-stronger write replaces the recorded value; a
      weaker value fills only an empty attribute
- [ ] 1.3 Batch merge (`merge_records_by_uid`): same order, same rule
- [ ] 1.4 Derive an address fallback name from the address kept after the
      address rank guard

## 2. Name precedence

- [ ] 2.1 Writers tag names: address fallback (passive census or hypervisor
      enrichment without a hostname) < passive census sighting with an
      observed hostname < automation inventory (AWX) name < SNMP `sysName` <
      hypervisor platform inventory name; `hostname` is gated by the same
      tiers and accepted or rejected together with `name`
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
      platform name leaves `vendor_name` unchanged; a metadata `Net-SNMP`
      leaves an OUI vendor in place and a metadata hardware vendor replaces it;
      an update classifying Linux with an OUI fills an empty vendor with the
      OUI; a census OUI `Ubiquiti Inc` leaves a recorded `sysObjectID`
      `Ubiquiti` in place

## 4. Type and integration type precedence

- [ ] 4.1 Writers tag `type`: generic `host` / default < fingerprint or
      classification-rule type < SNMP-derived type < platform-inventory type;
      `type` and `type_id` are accepted or rejected together; manual
      ownership keeps precedence over both
- [ ] 4.2 Writers tag `integration_type`: generic automation inventory <
      platform inventory that discovers the device as its own object
- [ ] 4.3 Test: alternating automation-inventory and hypervisor writes leave
      `type` and `integration_type` at the hypervisor values; a mapper
      `ip_forwarding` update leaves a hypervisor node's type `Hypervisor` and
      its `type_id` unchanged

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

## 6. Rollout

- [ ] 6.1 Release note: credential rules keyed on an exact OUI vendor string
      stop matching devices whose SNMP evidence derives a hardware vendor
      (hardware `sysObjectID` enterprise, or a hardware vendor from
      `sysDescr` or a classification rule even when the `sysObjectID` is under
      enterprise 8072); the OUI spelling remains for every device that does
      not derive a hardware vendor, including devices whose only vendor
      evidence is the OUI; legacy rows
      whose stored vendor was agent software, an OS or a software product
      start matching once the first census pass records the OUI vendor; rules
      keyed on fingerprint OS / software names in `vendor_name` must move to
      the OS / software fields
- [ ] 6.2 Verify on a deployment with existing inventory: config version of an
      affected agent changes at most once at the first census pass after
      rollout (a census name carrying an observed hostname, or an OUI vendor,
      replaces a value with no recorded strength; a hostname-less census name
      is the address fallback and never replaces a populated name without
      recorded strength or any stronger name) and at most once at the first
      mapper run (a stronger value replaces it); a legacy platform type or
      name may change once when the first above-weakest value is recorded
      and once more when the platform inventory records the strongest tier;
      only then does it stay constant across further census passes, mapper
      runs, automation-inventory cycles and hypervisor-enrichment cycles
