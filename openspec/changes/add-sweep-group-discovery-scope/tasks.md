# Tasks: Scope sweep device discovery to static targets

## 1. Model

- [x] 1.1 Add `SweepGroup.discover_new_devices` (non-null boolean, default
  true) and accept it on create and update.
- [x] 1.2 Add a hand-written additive migration with a column default and no
  row rewrite, and bump Helm `core.migrations.expectedVersion`. (Resource
  snapshots are absent for this resource, so `mix ash.codegen` is not used.)

## 2. Ingestion

- [x] 2.1 Add `SweepJobs.DiscoveryScope` to decide which answering hosts with
  no device a group may seed: setting on and address inside static targets
  (IPs, CIDRs, ranges; IPv4 and IPv6).
- [x] 2.2 Apply it to provisional-device seeding on the main and
  quarantined-reporter ingest paths. Keep host results and run totals for hosts
  that are not seeded.
- [x] 2.3 Log one line per batch with the count of hosts not added and the
  reason.

## 3. UI and docs

- [x] 3.1 Add the "Add newly found hosts to inventory" checkbox to the sweep
  group form and the setting to the group detail panel.
- [x] 3.2 Document the rule in `docs/docs/network-sweeps.md`.

## 4. Tests

- [x] 4.1 Unit tests for `DiscoveryScope` target forms, setting off, no static
  targets and unparseable entries.
- [x] 4.2 Ingest tests: query-only group seeds nothing but records the host
  result; static CIDR group seeds inside its range; mixed group seeds only
  inside static targets; setting off seeds nothing; quarantined-reporter path
  follows the same rule; existing rows take the default.
- [x] 4.3 LiveView test for the checkbox persisting the setting.
