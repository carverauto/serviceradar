# Change: Scope sweep device discovery to static targets, behind a group setting

## Why

When a sweep reports an answering host whose address has no device, result
ingestion seeds a provisional device for it. That is right for a group sweeping
static CIDRs or ranges, where finding new hosts is the point. It is wrong for
hosts the group's device query selected: those were devices when the agent
config compiled, so no device at the address now means the device was deleted
or moved since. Seeding there brings back an identifier-less copy of a device an
operator or a source removed. Purging inventory devices therefore cannot stick:
the next sweep of their former addresses recreates bare devices, and an address
a device moved away from gains a phantom.

Operators also have no way to keep a static-target group from adding to
inventory at all.

## What Changes

- Add `SweepGroup.discover_new_devices` (boolean, default `true`), shown in the
  sweep group form as "Add newly found hosts to inventory" and on the group
  detail panel.
- Sweep result ingestion seeds a provisional device for an answering host with
  no device only when the group's setting is on **and** the host's address is
  inside the group's static targets (single IPs, CIDRs or `first-last` ranges,
  IPv4 or IPv6). Hosts selected only by the device query never seed a device,
  whatever the setting says. The rule applies to quarantined-reporter results
  too.
- A host that is not seeded keeps its host result, recorded without a device
  and counted in the run's totals, the same as an unavailable unknown host.
  Ingestion logs one line per batch with how many hosts were not added and why.
- Schema: one additive column with a constant default. Existing groups take the
  default, so groups that discover through static targets keep doing so with no
  data backfill. The compiled agent config is unchanged; this is a core-side
  ingest decision.

## Impact

- Affected specs: `sweep-jobs`.
- Affected code: `SweepGroup` resource, a migration and the Helm
  `core.migrations.expectedVersion`, `SweepResultsIngestor` provisional-device
  seeding, a new `SweepJobs.DiscoveryScope`, the web-ng sweep group form and
  detail panel, `docs/docs/network-sweeps.md`.
- Behaviour change: a group with no static targets no longer seeds devices
  from its device query's results.
