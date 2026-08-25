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

- [x] 3.1 Registered under the distinct type `:interface_mac` (NOT `:mac` -- see the proposal's
  correction), via `Identity.InterfaceMacs`, wired into `ingest_interfaces/2` after device
  resolution. Writes are change-gated: existing values are read once per device and only new MACs
  are written, so a poll that discovers nothing new writes nothing. At 1M devices and 15 polls/day
  the unconditional version would be hundreds of millions of upserts/day.
- [x] 3.2 Only the device's OWN interface table feeds registration; neighbour tables are a different
  code path and are untouched. Covered by "an unrelated interface MAC does not lift the veto".
- [x] 3.3 Two independent guards: the mapper's existing `primary_identity_interface?/1` (no
  loopback/virtual/bridge/tunnel) and a refusal of locally-administered addresses -- 14 of 67
  interface MACs on the measured deployment.
- [ ] 3.4 Handle the U/L-flipped duplicate: `F692BF75C721` is the locally-administered form of
  `F492BF75C721` (EUI-64 derived). It must not register as a second distinct NIC.

## 4. Primary-address preference (#3905)

- [x] 4.1 `Identity.Address` (Elixir) and `platform.sr_address_rank/1` (SQL, by migration), pinned
  together by a parity test that caught a real divergence on its first run.
- [x] 4.2 Implemented as NEVER-DOWNGRADE in the upsert rather than only-promote: an equal-ranked
  address must still win or a genuine re-IP would be refused and every device would freeze at its
  first address.
- [x] 4.3 Covered: its current rank is equal, not higher, so the incoming value still applies.
- [ ] 4.4 Keep link-local/ULA recorded as aliases and valid sighting evidence.

## 4b. BLOCKING FINDING (2026-08-25): the path this unblocks is unreachable from bulk ingest

Verified on farm01 after deploying the veto narrowing:

- `AliasGuard.distinct_mac_conflict?(A, B)` now returns **false** -- the narrowing works, confirmed
  by calling it in a production pod against the real chassis pair.
- The pair still did not merge after 13 minutes.

The reason is structural, not a defect in this change. `maybe_merge_ip_alias_device/3` is called
ONLY from `identity/resolver.ex:79` and `:85`. `BatchResolver` -- which is what `SyncIngestor`
uses -- references `AliasGuard` **zero** times. Every bulk source (census, sweep, mDNS, netprobe,
armis) resolves through `BatchResolver`, so none of them can reach the alias merge.

Confirmed empirically rather than inferred: `platform.merge_audit` on farm01 holds 23 rows, ALL
`identifier_backfill` from `identity_reconciler` (the duplicate sweep), and **0** with reason
`ip_alias_conflict`. The alias merge has never run in this deployment's history.

So the chassis pair cannot merge today by either route: the alias path is unreachable from bulk
ingest, and the duplicate sweep needs a SHARED strong identifier, which two different interface
MACs are not.

- [ ] 4b.1 **DECISION NEEDED.** Two options, both with real blast radius at 50k-1M devices:
  - (a) Call the alias guard from `BatchResolver`. This enables alias-driven merges for EVERY bulk
    source at once -- behaviour that has never run in production. Needs the same measured
    blast-radius treatment the veto narrowing got before shipping.
  - (b) Teach `DuplicateSweep` to treat an own-interface MAC claim as shared evidence. Narrower,
    but it changes the sweep, which runs every five minutes over the whole device set.
- [ ] 4b.2 Whichever is chosen, measure how many pairs it would newly merge BEFORE shipping, the
  way the veto narrowing was measured -- it moved exactly one pair on 126 devices.

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
