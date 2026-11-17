## 1. Name placeholder never replaces an observed name

- [ ] 1.1 Upsert: keep the stored name when the update has no hostname, unless
      the stored name is empty or equals the stored address
- [ ] 1.2 Batch merge: derive the merged name the same way
- [ ] 1.3 Test: an observed name survives a hostname-less update; a placeholder
      follows an address change

## 2. OUI vendor is last resort across writes

- [ ] 2.1 Upsert: an OUI-derived vendor fills only an empty or OUI-derived
      stored vendor; provenance keys follow the kept value
- [ ] 2.2 Batch merge: same rule
- [ ] 2.3 Decide and implement the agent-software vendor question (design.md)
- [ ] 2.4 Test: reported vendor survives a census update; OUI replaces OUI

## 3. Per-integration identifiers

- [ ] 3.1 Decide storage (design.md) and stop AWX and Proxmox overwriting each other
- [ ] 3.2 Plugin assignment inputs read the provider's own id
- [ ] 3.3 Test: alternating AWX and Proxmox writes leave assignment inputs unchanged

## 4. Rollout

- [ ] 4.1 Release note: credential rules keyed on an exact OUI vendor string
- [ ] 4.2 Verify on a deployment: config version of an affected agent stays
      constant across two census passes and one mapper run
