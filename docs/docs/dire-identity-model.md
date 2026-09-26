# DIRE — Device Identity and Reconciliation Engine

How ServiceRadar decides "which device is this?" — the identity model,
merge policy, and lifecycle rules implemented under
`elixir/serviceradar_core/lib/serviceradar/inventory/identity/`.
The public entry point is `ServiceRadar.Inventory.IdentityReconciler`
(a facade; every ingestion path resolves through it — ingestors are
translators, never identity engines).

## Identifier vocabulary

| Type | Confidence | Notes |
|---|---|---|
| `agent_id` | strong | mTLS-validated agent identity; at most one connected agent per device (co-location is refused and alerted) |
| `armis_device_id` | strong | External platform id |
| `integration_id` | strong | Versioned + stable per external object; Proxmox admissibility and bridge formats are defined by [`IntegrationIdentity`](https://github.com/carverauto/serviceradar/blob/staging/elixir/serviceradar_core/lib/serviceradar/inventory/integration_identity.ex) |
| `netbox_device_id` | strong | External platform id |
| `mac` | strong / medium | Atomic, validated 12-hex values only; locally-administered MACs (IEEE bit) are medium and never merge on their own |
| IP | weak | Never an identifier; resolves a device only when **no** strong identifier is present |

Validation happens at every boundary (Go agent `syncsources.NormalizeUpdate`
and Elixir `Identity.Mac`): multi-value fields are split, malformed values
are rejected with telemetry, and rejected values never become rows.

### Integration identity admission

DIRE rejects bare numeric `integration_id` candidates regardless of provider.
An unscoped opaque candidate is also excluded when the update carries
`armis_device_id`, `netbox_device_id`, or a validated `hardware_serial`: it is
a legacy compatibility echo, not a second identity. Without typed evidence,
opaque candidates retain legacy admission. The extractor
[`Ids`](https://github.com/carverauto/serviceradar/blob/staging/elixir/serviceradar_core/lib/serviceradar/inventory/identity/ids.ex)
owns the scope recognition and admission rules.

The generic sync-service path scopes raw IDs before admission and retains a
lookup-only raw-ID bridge. Armis and NetBox keep their driver-owned formats
without core-side synthesis.

### Armis integration identity

The Armis driver emits `armis:<scope>:device:<native-id>` as `integration_id`
when `SyncServiceID` supplies a nonempty normalized scope. Scope normalization
lowercases the value and joins colon- or whitespace-separated segments with
dashes. Without that scope, the driver retains the legacy bare native ID;
it does not substitute the source key or partition.

DIRE admits the scoped Armis value through the generic integration lookup
and registration path, alongside `armis_device_id`. The driver's legacy bare
value follows the admission rules above. The typed identifier remains
source-authoritative for northbound write-back and drift repair. Northbound
selection accepts either the legacy bare metadata value or the scoped value
matching the source and typed ID; drift repair preserves valid scoped identities.

## Resolution order (single and batch)

Before allocating a new device, ingestion applies the source-specific
[creation evidence contract](https://github.com/carverauto/serviceradar/blob/staging/elixir/serviceradar_core/lib/serviceradar/inventory/sync/source_policy.ex)
in `SourcePolicy.sufficient_to_create?/1`.

1. Strong-identifier match (priority order above; `agent_id` matches are
   trusted-checked against the device's bound agent)
2. Pre-set `sr:` UUID — a hint, re-validated and canonical-followed
3. Deterministic UID derived from the highest-priority identifiers
4. IP/alias fallback — only for weak updates
5. Deterministic (IP-seeded) or random UID

A source-authoritative identifier (`armis_device_id`) decides identity. An
update carrying one never resolves, through a shared MAC or any other
identifier, onto a record that holds a different one in the same scope (the
identifier partition, which carries the sync source), whether that id is
stored or was claimed earlier in the same batch: that record is not a
match, the update resolves by its own identifier, and the shared identifier
stays with its owner as evidence. Each override is recorded as an open
`source_authoritative_override` source-identity conflict on the incoming
record, naming the overridden records and the identifiers they share, so it
can be reviewed. A record holding no source-authoritative identifier is still
a match: that is how an Armis id attaches to the discovered record of the same
device.

An address follows the device observed at it. When a strong-identified write
that observed the device at its address (Armis, the passive census,
mapper/SNMP discovery, an agent's self-report; see
`SourcePolicy.observed_address_source?/1`) lands on an address that a different
live device still holds (DHCP moved the address), and that observation is newer
than the holder's `last_seen_time`, the incoming device takes it and the stale
holder releases it: its IP is cleared in the same transaction and
it stays live. The decision is recorded as an open `active_ip_conflict`
source-identity conflict (proposed action
`preserve_source_identity_release_stale_ip`).

The holder keeps the address, and the incoming record drops it, in these cases
(the conflict is still recorded, with proposed action
`preserve_source_identity_drop_conflicting_ip`):

- the write comes from a declarative inventory (AWX, NetBox, Proxmox,
  hypervisor enrichment, generic integrations), whose address is configuration
  that can lag the network rather than a sighting;
- the observation is not newer than the holder's (older or equal, or either
  `last_seen_time` is missing), so an Armis last-known address of an offline
  device does not displace a live holder;
- another record in the same batch, the holder's own or a second incoming one,
  also claims the address: neither observation is fresher;
- the holder is bound to a different agent that is still live (an agent
  check-in only; live means not retired and seen within the last 30 minutes):
  two live agents behind one NAT address each keep their own device and the
  address does not flap between them. A holder bound to an agent that is
  gone, or with no agent, such as an Armis device, still releases a stale
  address to a newer check-in.

Two further cases adopt the holder's uid instead of moving the address: an
anchorless provisional seed at the address, and a holder whose hostname agrees,
under narrow conditions. A hostname is evidence, like the address, never
identity, so hostname agreement adopts the holder only when the incoming
record is not yet a device and neither side holds a source-authoritative
identifier (`armis_device_id`, `netbox_device_id`), with no disagreeing
hardware serial and no third device claiming either side's identity. It never
merges two existing devices and never adopts across a source-authoritative
identifier. When the hostnames agree but adoption is refused, the two stay
separate devices, the address is decided as above, and the pair is recorded as
a `policy_block` identity decision (reason `hostname_agreement_not_identity`),
which opens a de-duplication task for an operator to merge, mark distinct or
dismiss.

An agent check-in never adopts on hostname: `AgentGatewaySync` adopts a holder
only when it claims no anchor identifier (agent id, Armis id, MAC, serial, ...)
that the agent does not also claim. An agent's existing device is never
replaced by the holder; it takes the address under the rule above or keeps its
own, and either decision is recorded, with an evidence `reason`: `holder_stale`
(released), `holder_seen_no_earlier` or `held_by_live_agent` (kept). The holder
lookup for a new agent device is scoped to that device's partition; a missing or
blank partition on the check-in is `default`, for the device and the lookup.

Merged-away device IDs are never resurrected: resolution follows the
`merge_audit` canonical mapping to the survivor (`Identity.Resolver` /
`Identity.BatchResolver`), including after the tombstone row has been purged,
unless an unmerge reversed that merge.

A strong match in `Identity.Resolver` considers every record that owns one of
the update's globally-unique MACs, not only the owner of the first MAC found.
When those are two or more records, the split is a conflict for the merge
policy below. A locally-administered MAC never adds a record to the conflict.

### SNMP mapper polls

A device the mapper polls is identified by the MACs its own physical
interfaces report, never by the address it was polled at. DHCP hands that
address to other devices, so the record holding it, or a confirmed alias of
it, may describe a different device. The MACs resolve through the steps
above, and they are registered as the device's interface claims only after
that. The polled address is evidence only: it breaks a tie between records
the MACs identify.

- A new device is written at the polled address under the same active-address
  rules as any strong write.
- An existing device moves to the polled address only when its recorded
  address is not one its interfaces still report, so a router polled at its
  WAN and LAN addresses keeps one address. The address follows the newer
  observation: a live holder last seen before the poll releases it in the same
  transaction, and a holder that is not older keeps it, with an
  `active_ip_conflict` recorded.
- Only globally-unique MACs identify a device. A poll that reports no
  globally-unique interface MAC, whether it has none or only randomized ones,
  falls back to the address: the live holder, then a confirmed alias, then an
  address-seeded device.
- A poll never revives a device an operator deleted, one a merge
  tombstoned, or one a DIRE remediation removed (`deleted_reason` starting
  with `dire_remediation`). A device another automatic process deleted (a
  `system:` actor, such as a reaper or an expiry) came back online and is
  restored through the audited `:restore` action, which bumps the identity
  revision and records the revival. When its old address has since been
  leased to another live device, the restore clears it and the device moves
  to the polled address; the other device keeps its address.

## Merge policy and stability

- Evidence gates (`Identity.MergePolicy`): never merge on agent_id-only or
  randomized-MAC-only match sets. A globally-unique MAC is hardware identity:
  records that share one, or that one device's interfaces report together,
  converge, and the merge is recorded in `merge_audit`. A record linked to a
  conflict only through a randomized MAC drops out of the merge, recorded as a
  `randomized_mac_link` policy block.
- Stability guards (`Identity.MergeEngine`, every automatic merge):
  - devices bound to **different agents** never merge; a conflicting IP
    alias is invalidated (`mark_stale`) instead
  - per-pair cooldown (default 24h, either direction) breaks merge
    oscillation; blocked re-merges alert via telemetry
- Merges are transactional, audited (`merge_audit`), and move every
  linked record (identifiers, service checks, alerts, agents, per-agent
  availability, alias states, interfaces, endpoint inventory).
  `unmerge_device` restores a tombstoned device in place from the audit
  trail (the original IP is reclaimed only if unheld). Every merge records
  the merged-away device's own identifiers in
  `merge_audit.details.source_identifiers`; an unmerge moves back exactly
  those the survivor still holds, never the survivor's own. Merge rows
  written before that field existed restore only the merged-away device's
  conflict matches, or nothing.
- Identifier ownership never changes silently: upserts do not re-point
  `device_id` on conflict; moves happen via merges or the explicit
  `:reassign_device` action.
- A merge survivor retains the earliest non-null `first_seen_time` of the
  two devices, so merging an older identity into a newer row does not make
  the host newly discovered in the "Recently added devices" report.

For deliberate cross-cluster Proxmox splits, use the
[`serviceradar.dire_remediation` command help](https://github.com/carverauto/serviceradar/blob/staging/elixir/serviceradar_core/lib/mix/tasks/serviceradar.dire_remediation.ex)
for dry-run review, execution gates, and device/source allowlists.

## Lifecycle

- Per-(device, type) cardinality caps with supersede-by-`last_seen`
  (`Identity.CardinalityCaps`; defaults mac: 64, others: 8; config
  `:serviceradar, ServiceRadar.Inventory.Identity.CardinalityCaps`).
  Retirements are logged with values and counted in telemetry.
- TTL garbage collection for unseen identifiers (default 90 days;
  `DeviceIdentifierGcWorker`).
- Ephemeral device expiry (`EphemeralDeviceExpiry`, run by `DeviceCleanupWorker`; off by
  default, Settings -> Networks -> Inventory Cleanup): a live device holding no strong
  identifier -- no agent, source-authoritative id, hardware serial or globally-unique MAC --
  and unseen past the window (default 30 days) is soft-deleted as `stale_ephemeral`.
  Operator-created devices and devices matching the exclusion SRQL query never expire; a pass
  that would expire more than `ephemeral_expiry_max_fraction` of live devices is refused
  unless the override is set. Telemetry: `[:serviceradar, :inventory, :ephemeral_expiry,
  :run]`, `:refused` and `:failed` (a raised pass, which never stops the purge). A returning device is restored with a revival audit row.
- Scheduled duplicate reconciliation (`Identity.DuplicateSweep`) is
  bounded (DB-side duplicate grouping, capped merges per run) and obeys
  the same merge policy as ingest; schedule health is monitored so a
  silently-dead cron alerts.
- Agent↔device links self-heal periodically (`AgentLinkRepairWorker`).

## Telemetry (alert on these)

| Event | Meaning |
|---|---|
| `[:serviceradar, :identity_reconciler, :identifier, :rejected]` | malformed identifier value dropped at the boundary |
| `[:serviceradar, :identity_reconciler, :identifier, :truncated]` | per-update MAC sanity cap hit |
| `[:serviceradar, :identity_reconciler, :identifier, :retired]` | per-device cardinality cap enforced |
| `[:serviceradar, :identity_reconciler, :merge, :guard_blocked]` | distinct-agent veto or cooldown blocked a merge (oscillation signal) |
| `[:serviceradar, :identity_reconciler, :merge, :blocked]` | evidence policy blocked a merge |
| `[:serviceradar, :identity_reconciler, :alias, :invalidated]` | IP alias conflicted with agent identity |
| `[:serviceradar, :identity_reconciler, :source_identity, :source_override]` | a source-authoritative identifier overrode identifier matches on records holding a different one (also persisted as a `source_authoritative_override` conflict) |
| `[:serviceradar, :identity_reconciler, :agent_colocation, :refused]` | second agent refused onto an agent-bound device |
| `[:serviceradar, :identity_reconciler, :decision, :record_failed]` | an identity decision could not be written to `platform.identity_decisions` |
| `[:serviceradar, :identity_reconciler, :deduplication_task, :open_failed]` | a de-duplication task could not be opened or updated for a recorded decision |

## Identity decisions

Every decision that blocks, declines or overrides a merge is also written to
`platform.identity_decisions` (`ServiceRadar.Inventory.IdentityDecision`), so it can be
reviewed later instead of living only in telemetry. One row per distinct decision: the
kind (`policy_block`, `guard_block`, `source_block`, `alias_invalidated`, `ip_conflict`,
`source_override`, `component_block`), the reason, the sorted device set, the address it concerns, the latest
evidence, and how often and when it was made. A repeat updates the row rather than adding
one. Administrative merges are not decisions and are not recorded.

## De-duplication tasks

Every identity decision that names two or more devices also opens or updates the
de-duplication task for that device set (`platform.identity_deduplication_tasks`,
`ServiceRadar.Inventory.DeduplicationTask`); the scheduled duplicate sweep records each
ambiguous component it declines the same way (`component_block`). There is exactly one task per
device set for its whole life; later decisions update its count, last reason and evidence.

An operator resolves an open task through `ServiceRadar.Inventory.Identity.Deduplication`:

- `merge/4` merges every other device into a chosen survivor through the administrative merge
  path (reason `manual_dedup_task`). If a merge fails the task stays open; a retry treats
  devices already merged into the survivor as done.
- `mark_distinct/3` records a `DistinctDeviceAssertion` for every pair
  (`platform.identity_distinct_assertions`). `MergeEngine` then refuses every automatic merge of
  those pairs (guard `asserted_distinct`), the scheduled backfill included, and later decisions
  about the set open no task.
- `dismiss/3` closes it without a decision; a dismissed task can be reopened.

## Release gate

`test/serviceradar/inventory/identifier_cardinality_gate_test.exs`
(tag `large_ingestion`): repeated churned ingest rounds must not grow
`device_identifiers` beyond true per-device sets — the regression gate
for the 12.3M-row identifier explosion.

History and rationale: `openspec/changes/refactor-device-identity-reconciliation/`
(proposal, design, and the live-system investigation that drove it).
