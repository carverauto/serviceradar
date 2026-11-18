## 1. Recorded strength for single-valued attributes

- [ ] 1.1 Store source and evidence strength alongside `name` and `vendor_name`;
      a populated value with no recorded strength is kept against weakest-tier
      writes; the next middle- or strongest-tier write replaces it and records
      its strength
- [ ] 1.2 Upsert: replace a stored value only with equal or greater strength;
      a weaker value fills only an empty attribute
- [ ] 1.3 Batch merge (`merge_records_by_uid`): same order, same rule
- [ ] 1.4 Derive an address fallback name from the address kept after the
      address rank guard

## 2. Name precedence

- [ ] 2.1 Writers tag names: address fallback < passive census sighting <
      SNMP `sysName` / integration-reported
- [ ] 2.2 Test: a `sysName` survives a hostname-less census update, in one
      batch and across batches
- [ ] 2.3 Test: a hostname-less sighting of a rejected address does not rename
      the device

## 3. Vendor precedence

- [ ] 3.1 Writers tag vendors by the vendor derived for the update: derived
      vendor naming agent software (any channel) < IEEE OUI / non-integration
      metadata vendor < derived hardware vendor (`sysObjectID` enterprise,
      `sysDescr` or classification rule, including under enterprise 8072) /
      integration-reported; a `sysDescr` or classification result naming
      agent software never replaces a populated value; provenance keys follow
      the kept value
- [ ] 3.2 Keep the agent-software enterprise list (Net-SNMP 8072 and similar)
      next to the enterprise-to-vendor table
- [ ] 3.3 Test: a hardware-enterprise vendor with recorded strength survives
      an OUI update; an OUI vendor survives an update whose derived vendor
      names agent software (Net-SNMP); a hardware vendor from `sysDescr` or a
      classification rule replaces the OUI vendor even when the `sysObjectID`
      is under enterprise 8072; OUI replaces OUI
- [ ] 3.4 Test: a `sysDescr`-inferred hardware vendor with recorded strength
      survives an OUI-only update

## 4. Per-integration identifiers

- [ ] 4.1 Decide storage (design.md) and stop AWX and Proxmox overwriting each other
- [ ] 4.2 Plugin assignment inputs read the provider's own id
- [ ] 4.3 Test: alternating AWX and Proxmox writes leave assignment inputs unchanged

## 5. Rollout

- [ ] 5.1 Release note: credential rules keyed on an exact OUI vendor string
      stop matching devices with a hardware-enterprise SNMP vendor or a
      hardware vendor from `sysDescr` or a classification rule (even when the
      `sysObjectID` is under enterprise 8072); only devices whose derived
      vendor names agent software keep the OUI vendor, and legacy rows whose
      stored vendor was agent software start matching once the first census
      pass records the OUI vendor
- [ ] 5.2 Verify on a deployment with existing inventory: config version of an
      affected agent changes at most once at the first census pass after
      rollout (a census name carrying an observed hostname, or an OUI vendor,
      replaces a value with no recorded strength; a hostname-less census name
      is the address fallback and never replaces a populated name) and at
      most once at the first mapper run (a stronger value replaces it), then
      stays constant across further census passes and mapper runs
