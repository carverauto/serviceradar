# Tasks

## 1. Reproduce both defects before changing anything

- [ ] 1.1 DB-backed test for the chassis split: a device holding interface MACs `...c7:2a` and
  `...c7:2b`, a separate device already carrying `...c7:2b`, and the assertion that they do NOT
  merge today. It must FAIL after interface-MAC registration lands.
- [ ] 1.2 DB-backed test for #3905: a device whose primary IP is `fe80::...` while a routable alias
  is present, asserting the primary stays link-local today.
- [ ] 1.3 Register the tests in `test/INTEGRATION_SOURCE_DISPOSITIONS.tsv` and project into
  `build/integration_test_dispositions.bzl`, or add them to an already-registered source with the
  same disposition and update its selected-test count. There is no generator;
  `//:ci_heavy_gate_contract_test`, `//build:integration_selection_equivalence_test` and
  `//build:integration_shards_topology_test` all enforce the projection, and the shard topology
  pins exact per-lane counts.

## 2. Bind addresses to interfaces

- [ ] 2.1 Find why `eth10` is stored with an empty `ip_addresses` while the device holds
  `192.168.1.1` as a confirmed alias — the address is reaching the device but not the interface.
  Fix at the source of that split rather than back-filling afterwards.
- [ ] 2.2 Confirm the SNMP walk reads `ipAddressTable` (IPv4 + IPv6), not only the IPv4-only
  `ipAddrTable`.

## 3. Register interface MACs as identifiers

- [ ] 3.1 Register MACs from the device's OWN interface table as strong identifiers of that device.
- [ ] 3.2 Enforce the boundary: neighbour/observed MACs MUST NOT be registered as identifiers of the
  observing device. This is the over-merge risk; make it a test, not a comment.
- [ ] 3.3 Reuse the existing eligibility rules rather than restating them — locally-administered and
  randomized MACs do not anchor (`census_anchorable_mac?/1`), and the polling-agent exclusion holds.
- [ ] 3.4 Handle the U/L-flipped duplicate: `F692BF75C721` is the locally-administered form of
  `F492BF75C721` (EUI-64 derived). It must not register as a second distinct NIC.

## 4. Primary-address preference (#3905)

- [ ] 4.1 Implement the ranking: routable > private > ULA > link-local; loopback never primary.
- [ ] 4.2 Promote an existing routable alias when the primary is link-local or ULA. Promotion must
  not create a device or change which device an address resolves to.
- [ ] 4.3 A device with no routable address keeps its current primary rather than being emptied.
- [ ] 4.4 Keep link-local/ULA recorded as aliases and valid sighting evidence.

## 5. Verify against the real data

- [ ] 5.1 Re-run 1.1 and 1.2 and confirm both now fail to reproduce.
- [ ] 5.2 On farm01, confirm the chassis pair merges — and gate on the ARTEFACT: query
  `platform.merge_audit` for a new row joining them, and confirm the run postdates the rollout.
- [ ] 5.3 Confirm the link-local count falls. Baseline measured 2026-08-24: **18** devices with an
  `fe80:` primary, **7** with a ULA, out of **126** live; **10 of the 18** already hold an IPv4
  alias and so should flip on promotion alone. The remaining 8 have no routable address recorded
  and SHOULD NOT change — a drop to zero would mean addresses were blanked, not promoted.
- [ ] 5.4 Confirm no device count collapse: compare live device totals before/after. A large drop
  means over-merge, which is the failure this design is shaped to avoid.

## 6. Related, deliberately not fixed here

- [ ] 6.1 `platform.discovered_interfaces` holds ~118 duplicate rows per interface for the
  motivating device (e.g. `eth9` idx 3 appears 118 times with identical content, plus permutations
  of the same `ip_addresses` array). Write it up as its own issue: it is a write-path defect, it
  inflates every interface read, and the permutation rows suggest the array is unordered where the
  uniqueness check expects order.

## 7. Close out

- [ ] 7.1 `openspec validate update-device-identity-interface-and-address-selection --strict`
- [ ] 7.2 Close GitHub #3905 referencing the requirement and the measured before/after.
