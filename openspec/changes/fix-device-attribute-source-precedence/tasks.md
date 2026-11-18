## 1. Recorded strength for single-valued attributes

- [ ] 1.1 Store source and evidence strength alongside `name` and `vendor_name`;
      a stored value with no recorded strength counts as the weakest
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

- [ ] 3.1 Writers tag vendors: agent-software `sysObjectID` enterprise < IEEE
      OUI < hardware-enterprise `sysObjectID` / integration-reported;
      provenance keys follow the kept value
- [ ] 3.2 Keep the agent-software enterprise list (Net-SNMP 8072 and similar)
      next to the enterprise-to-vendor table
- [ ] 3.3 Test: a hardware-enterprise vendor survives an OUI update; an OUI
      vendor survives a Net-SNMP agent vendor; OUI replaces OUI

## 4. Per-integration identifiers

- [ ] 4.1 Decide storage (design.md) and stop AWX and Proxmox overwriting each other
- [ ] 4.2 Plugin assignment inputs read the provider's own id
- [ ] 4.3 Test: alternating AWX and Proxmox writes leave assignment inputs unchanged

## 5. Rollout

- [ ] 5.1 Release note: credential rules keyed on an exact OUI vendor string
      stop matching devices with a hardware-enterprise SNMP vendor
- [ ] 5.2 Verify on a deployment: config version of an affected agent stays
      constant across two census passes and one mapper run
