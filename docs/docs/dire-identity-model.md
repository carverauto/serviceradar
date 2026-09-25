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
identifier partition, which carries the sync source): that record is not a
match, the update resolves by its own identifier, and the shared identifier
stays with its owner as evidence. Each override is recorded as an open
`source_authoritative_override` source-identity conflict on the incoming
record, naming the overridden records and the identifiers they share, so it
can be reviewed. A record holding no source-authoritative identifier is still
a match: that is how an Armis id attaches to the discovered record of the same
device.

Merged-away device IDs are never resurrected: resolution follows the
`merge_audit` canonical mapping to the survivor (`Identity.Resolver` /
`Identity.BatchResolver`), including after the tombstone row has been purged,
unless an unmerge reversed that merge.

## Merge policy and stability

- Evidence gates (`Identity.MergePolicy`): never merge on agent_id-only,
  MAC-only, or medium-confidence-only match sets.
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

## Identity decisions

Every decision that blocks, declines or overrides a merge is also written to
`platform.identity_decisions` (`ServiceRadar.Inventory.IdentityDecision`), so it can be
reviewed later instead of living only in telemetry. One row per distinct decision: the
kind (`policy_block`, `guard_block`, `source_block`, `alias_invalidated`, `ip_conflict`,
`source_override`), the reason, the sorted device set, the address it concerns, the latest
evidence, and how often and when it was made. A repeat updates the row rather than adding
one. Administrative merges are not decisions and are not recorded.

## Release gate

`test/serviceradar/inventory/identifier_cardinality_gate_test.exs`
(tag `large_ingestion`): repeated churned ingest rounds must not grow
`device_identifiers` beyond true per-device sets — the regression gate
for the 12.3M-row identifier explosion.

History and rationale: `openspec/changes/refactor-device-identity-reconciliation/`
(proposal, design, and the live-system investigation that drove it).
