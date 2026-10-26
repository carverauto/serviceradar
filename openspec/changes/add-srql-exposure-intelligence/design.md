# Design: Exposure intelligence in SRQL

## Context

What exists today:

| Fact | Store | Identity | SRQL today |
|---|---|---|---|
| Device x package x CVE applicability decision | CNPG `platform.endpoint_vulnerability_assessments` | `(device_uid, package_identity_key, cve_id)`; version-independent package identity | `in:endpoint_vulnerability_assessments`, `in:devices cve:` / `kev:` (EXISTS) |
| KEV, exploit, CVSS on the assessment; EPSS when the payload carries it | same row (`kev`, `exploit_available`, `cvss_score`, `metadata.epss_score`) | as above | as above |
| Device fleet ordinal (`uid -> integer`) | CNPG `platform.device_fleet_ordinals`, allocated lazily for every non-service device, tombstoned on merge | `ordinal` from a sequence | none |
| Network flows | StarRocks `serviceradar.ocsf_network_activity` (the only flow store) | flow id; `device_uid` is the **exporter**, not an endpoint | `in:flows` |
| Process attribution on flows | same table (`pid`, `comm`, `container_id`, `workload_identity`) | flow id | `in:attributed_flows` |
| Socket ownership and host peer evidence | leases, an in-memory ownership index and per-process connection summaries (`host_connection_summaries`), as specified by the merged change `stream-flow-attribution-via-ownership-index` (#5753); being implemented | `(partition, proto, ip, port)`; summaries per `(agent, owner, local endpoint, peer endpoint, proto, direction)` | none |
| IOC matches | CNPG `platform.ip_threat_intel_cache`, populated from IPs seen in flows | ip | `in:threat_intel_matches`, `threat_*` filters on flows (StarRocks reads the matched set through `cnpg_platform.native_query`) |
| Topology | graph (AGE / Dgraph) | device uid | `in:device_graph`, `in:graph_cypher` |
| BGP | StarRocks BMP events | peer, prefix | `in:bmp_events` |
| Small current-state dimensions | CNPG, reachable from StarRocks through the opt-in `cnpg_platform` JDBC catalog, with column-scoped grants to `serviceradar_starrocks_reader` and an allowlist in `CatalogAllowlist` | | used by flow enrichment joins |
| Current exposure facts, CVE and package dimensions, and transition history | StarRocks migration 0032 (`exposure_facts`, `exposure_cve_dim`, `exposure_package_dim`, `exposure_transitions_log`) plus 0033 (`transition_seq` on the two dimensions) and 0034 (`device_lifecycle_seq`, `exposure_retired_ordinals`); see Decisions 21, 22 and 23 | fact key `(device_ord, cve_ord, pkg_ord)` | none yet |

The gaps that block the six operator questions are:

- nothing maps a flow endpoint or a host peer to a device;
- executable ownership is on flow attribution events and process snapshots (task 0.3); lease owner records and connection summary rows still lack it (task 0.4);
- host connection summaries (#5753) are not yet in the lab warehouse (Task 0.5), so nothing joins them to devices, exposure or flows, and nothing records whether an agent's capture was complete for an interval;
- the exposure tables above are not yet written or exposed as SRQL.

A pre-fix lab measurement for #5749 found about 97% of "active" match rows were orphans. The 2026-10-22 read-only follow-up, after a successful matcher completion, found no active orphan matches and an actionable assessment count rounded to zero (nearest hundred). See *Task 0.2: read-only cleanup follow-up*.

## Goals / Non-Goals

Goals:

- Answer the six operator questions as single SRQL queries within stated latency budgets
  at 20k hosts.
- Treat host, network and corroborated evidence as one set, with provenance on every
  answer. Host-only deployments are first-class.
- Detect network-only connections to fully covered hosts (evasion) and host-only
  connections through monitored exporters (coverage gaps). Every false-positive control
  is written down and tested.
- Keep the matcher the single source of applicability truth. Exposure is a projection of
  assessments, never a second matcher.
- Keep every write on JetStream first, then EventWriter.

Non-Goals:

- Re-evaluating version ranges anywhere other than `EndpointVulnerabilityMatcher`.
- A second risk score: `DeviceRiskReducer` stays the only writer of `risk_score`.
- Exposure facts for devices without package inventory. Agentless devices appear as
  network evidence and as blast-radius neighbours only.
- Automatic blocking, quarantine or any response action.
- Packet payload capture or exploit-signature detection.
- Bitmaps inside the matcher. Candidate discovery is a key lookup (#5748).
- Backfilling historical flows with device ordinals or attribution outcomes.
- Coverage attestation on Windows and macOS agents at launch, because neither has
  event-driven socket capture.
- The canonical CTI sighting model, which `add-cti-signal-coverage` owns.
- Multitenancy.

## Data flow

```
CNPG assessments --(outbox, same txn)--> JetStream vulnerability.assessment.transitions.<bucket>
   (matcher, #5748)                                  |
                                                     v
                                   EventWriter ExposureTransitions --> SR exposure_facts (PK)
                                                     |                  SR exposure_transitions_log
                                                     |                       |
                                                     |                  async MVs: cve->devices, kev devices,
                                                     |                  severity->devices, device summary
                                                     |                       |
                                                     |                  daily job --> SR exposure_daily (bitmaps)
core exposure publisher --> exposure.dimensions.{cve,package,address}
                                                     |
                                                     v
                                   EventWriter --> SR exposure_cve_dim, exposure_package_dim,
                                                   exposure_device_addresses (validity intervals)
                                                     |
             +---------------------------------------+ (same stream also feeds the flow tier's
             |                                         bounded address validity history)
             v
flows.raw.* --> EventWriter flow tier: attribute (ownership index) + resolve endpoints at
                observation time + stamp src/dst_device_ord, src/dst_device_resolution,
                src/dst_attribution_outcome --> SR ocsf_network_activity
                       |                         |
                       | evidence deltas         | final no_owner on an attested address
                       v                         v
              SR observed_connections_hourly   JetStream exposure.discrepancy.candidates
                       ^                         |
agent summaries -------+                         v
 (flows.connections.summary)            core DiscrepancyEvaluator (sharded)
agent attestations --> SR agent_capture_coverage   |  waits for attestation, checks host evidence,
 (flows.connections.coverage)                   |  scores, or records a suppression
                                                v
                                 JetStream exposure.discrepancies --> EventWriter
                                      --> SR connection_discrepancies + OCSF Detection Finding
                                      --> StatefulAlertEngine (incident grouping)
```

`SR` is StarRocks. Subject names are proposals. #5748 owns the transitions subject name,
`flows.connections.summary` and the `flow_connections` stream are defined by the merged
`stream-flow-attribution-via-ownership-index` change; `flows.connections.coverage` is added
to that stream by this change.

## Decisions

### Decision 1: StarRocks holds exposure, next to flows

Exposure is only valuable when it is combined with traffic, and flows exist only in
StarRocks (when StarRocks is enabled it is the only flow store). Putting the exposure
state next to flows turns every showcase question into one warehouse query.

Alternatives considered:

- **`pg_roaringbitmap` in CNPG.** Rejected, for three reasons:
  - Exposure x traffic would need flows in CNPG, which is forbidden, or bitmaps carried
    over JDBC. JDBC has no BITMAP type and does not push down aggregates.
  - It needs a custom extension in the CNPG image, with the cross-libc build and upgrade
    burden that image already carries.
  - Rewriting bitmaps adds WAL to the control-plane database.
- **A Rust NIF over the workspace `roaring` crate.** Rejected:
  - The state lives per BEAM replica, so every node has to rebuild and stay consistent.
  - It uses core pod memory.
  - It has no persistence or history.
  - Each traffic question would still ship device sets to StarRocks as IN lists.
  - It reimplements what the warehouse already provides.
- **A StarRocks external catalog over the CNPG assessments.** Rejected. Aggregates and
  joins do not push down through JDBC, so every query would pull millions of assessment
  rows across the network and load the control-plane database.

### Decision 2: A Primary Key fact table keyed on the assessment identity

```sql
CREATE TABLE IF NOT EXISTS serviceradar.exposure_facts (
  device_ord          BIGINT    NOT NULL,
  cve_ord             BIGINT    NOT NULL,
  pkg_ord             BIGINT    NOT NULL,   -- version-independent package identity
  pkgver_ord          BIGINT    NOT NULL,   -- identity + installed version
  state               TINYINT   NOT NULL,   -- 1 active (actionable), 0 resolved, 2 retired
  source_scope        VARCHAR(32),
  severity_rank       TINYINT,              -- 0 none, 1 low, 2 medium, 3 high, 4 critical
  cvss_score          DECIMAL(3,1),
  kev                 BOOLEAN,
  exploit_available   BOOLEAN,
  fix_available       BOOLEAN,
  first_exposed_at    DATETIME,
  resolved_at         DATETIME,
  updated_at          DATETIME  NOT NULL,
  transition_seq      BIGINT    NOT NULL,
  transition_xid      BIGINT    NOT NULL,   -- CNPG xact id of the producing transaction
  snapshot_generation BIGINT    NOT NULL DEFAULT "0",
  device_lifecycle_seq BIGINT   NOT NULL DEFAULT "0"  -- appended by migration 0034; Decision 23
)
PRIMARY KEY (device_ord, cve_ord, pkg_ord)
DISTRIBUTED BY HASH(device_ord) BUCKETS 16
ORDER BY (cve_ord, device_ord)
PROPERTIES ("replication_num" = "3", "enable_persistent_index" = "true");
```

- **The key follows the assessment identity.** The CNPG unique index is `(device_uid,
  package_identity_key, cve_id)`, and the package identity is version-independent. The
  key is therefore `(device_ord, cve_ord, pkg_ord)`, and `pkgver_ord` is a column.
  - An upgrade that fixes the CVE resolves the same row. An upgrade that does not fix it
    updates `pkgver_ord` in place.
  - The epic comment proposed keying on `pkgver_ord`. That would leave the pre-upgrade row
    behind unless a separate delete raced the insert, which is exactly the orphan bug
    #5749 describes on the CNPG side.
- **"Active" is the exact actionable predicate:** `status = active AND assessment =
  confirmed AND disposition = affected`. This is the triple
  `add-srql-advisory-cpe-entities` defines. Candidates are not exposure.
- **Resolution is a state change, never a delete.** Deletion and retirement are transitions
  too: each draws a **new** `transition_seq`, greater than the key's last one, and carries
  an explicit terminal state (`resolved` or `retired`). A terminal transition never reuses
  the key's last sequence.
  - Every transition carries the complete after-image of every fact column except
    `snapshot_generation`, never only the changed fields. A greater `transition_seq`
    applies the after-image; an equal sequence may replay the identical after-image.
    Changed content requires a new sequence at the producer, serialized on the full fact
    key (Decision 20), with the assessment row locked when present.
    An older sequence is rejected. Live Stream Load uses row-mode partial updates with
    every event-owned column explicitly listed, excluding `snapshot_generation`, so
    replay preserves the snapshot marker. A newly inserted fact defaults that marker to 0.
  - Device lifecycle sequencing (Decision 23) is checked before a fact load. An
    authorized restoration can publish fresh facts under the same fleet ordinal;
    messages from its earlier lifecycle can never reactivate it.
  - A resolution is written as `state = 0` and the row stays as a tombstone carrying its
    `transition_seq`.
  - **The row is the fact's sequence watermark, and it is kept permanently.** A daily
    compaction clears only the payload columns of tombstones resolved more than 7 days ago,
    leaving the key, `state = 0`, `transition_seq`, `transition_xid` and
    `snapshot_generation`. An identical terminal replay may restore cleared payload,
    which the next compaction can clear again; it cannot reactivate the fact. Correctness
    therefore does not depend on any delivery horizon: an older active transition delivered
    at any later time still loses to the watermark. Watermark rows cost about 24 bytes each
    before compression, and their number is bounded by the fact keys ever seen, because the
    package identity is version-independent.
  - Delivery delay is bounded for freshness, not for correctness: the oldest unrelayed
    outbox row must be younger than 10 minutes, and the transitions stream keeps messages
    for at most 7 days (`max_age`). Exceeding either raises a health alert. Relayed outbox
    rows are deleted once acknowledged.
- **`transition_seq`** comes from one CNPG sequence. The producer draws it in the same
  transaction as the assessment change or terminal watermark. Every creation, update,
  deletion and repair serializes on the full fact key, even when no assessment exists;
  an existing assessment row is also locked. The sequence is stored on the assessment
  or terminal watermark. This serialization makes the sequence follow commit order per
  fact, including deletion and re-creation (Decision 20). Across facts it does not, which
  is why the snapshot fence (Decision 14) uses the database snapshot rather than a
  sequence threshold.
- **`transition_xid`** is `pg_current_xact_id()` of the producing transaction, recorded on
  the outbox row and carried on the transition. It is 64-bit and does not wrap.
- **`ORDER BY (cve_ord, device_ord)`** makes "devices exposed to CVE-X" a prefix-index
  range scan. Distributing by `device_ord` keeps the evidence join co-located.
- **EPSS is not on the fact row.** EPSS changes daily for nearly every CVE. Denormalizing
  it would turn one feed refresh into tens of millions of transitions. It lives on
  `exposure_cve_dim` (about 250k rows, upserted once a day), which StarRocks joins natively.
  KEV changes rarely and drives the KEV bitmap, so it stays on the fact row; the matcher's
  overlay already stamps it on the assessment (`add-cve-priority-context`).

### Decision 3: Bitmaps are derived materialized views

```sql
CREATE MATERIALIZED VIEW serviceradar.exposure_cve_devices_mv
REFRESH ASYNC EVERY (INTERVAL 60 SECOND) AS
SELECT cve_ord, bitmap_union(to_bitmap(device_ord)) AS devices, count(*) AS facts
FROM serviceradar.exposure_facts WHERE state = 1 GROUP BY cve_ord;
```

The views are:

- `exposure_cve_devices_mv` (CVE -> devices);
- `exposure_risk_devices_mv` (`severity_rank`, `kev` -> devices);
- `exposure_device_summary_mv` (per device: exposure count, KEV count, critical count,
  maximum CVSS).

They serve aggregate and set-algebra queries such as host counts, AND/OR/ANDNOT of device
sets, and slicing.

Why an Aggregate `BITMAP_UNION` table cannot be the system of record:

- An Aggregate Key table merges each newly loaded row into the stored value with its
  aggregate function. `BITMAP_UNION` can only set bits, so removing device 42 from
  CVE-X's bitmap after an upgrade is not expressible.
- The only workaround is a `REPLACE` bitmap recomputed from the complete current device
  set for that CVE. That needs a system of record elsewhere anyway, and it rewrites a
  20k-member bitmap for one device's change.
- A union also cannot express "apply only if newer", so redelivery and reordering corrupt
  it.

The Primary Key table supports per-fact conditional upsert, and the views recompute the
union from current rows.

The views refresh in full, because the base table is not partitioned. The refresh budget
is a requirement. SRQL reads a view only for aggregates, and only while its last refresh
is within the staleness budget; otherwise it falls back to the fact table. Each response
carries an `as_of` for each source it read.

### Decision 4: Collision-free identifier dictionaries

- **`device_ord`.** Reuse `platform.device_fleet_ordinals` (u32 range, sequence-allocated,
  never reused, tombstoned on merge).
  - Allocation covers every non-service device, widened from endpoint-inventory
    devices, so agentless devices the address publisher emits can carry network
    evidence and act as blast-radius members. A read-only lab transaction found no
    live, non-service device missing a non-tombstoned ordinal. The maximum allocated
    ordinal, rounded up, was below 0.4 million; more than 99.99% of the u32 range
    remained (Task 0.7).
  - When a merge or deletion tombstones an ordinal, the publisher emits a `device_retired`
    transition with a new `transition_seq` `R`, drawn in the transaction that tombstones the
    ordinal and recorded on the ordinal row (`retired_seq`); it is greater than every
    sequence the ordinal's facts carry. No later assessment transition is produced
    while that ordinal remains tombstoned.
    EventWriter sets every fact of the ordinal to `state = 2` (retired) at `R`, closes its
    address intervals, and records the ordinal in the permanent
    `serviceradar.exposure_retired_ordinals`. This permanent lifecycle record retains the
    last retirement watermark and the latest lifecycle state and sequence. An authorized
    restoration keeps the ordinal and emits a newer `device_restored` marker; current
    assessments are republished under that lifecycle (Decision 23). The ingestion boundary
    drops and counts older-lifecycle facts, including previously unseen keys, and defers
    future-lifecycle facts until their marker arrives. The survivor's assessments re-emit
    under the survivor's ordinal.
- **`cve_ord`.**
  - For `CVE-YYYY-N` with `N < 10^7`, the ordinal is `YYYY * 10^7 + N` (for example
    `CVE-2024-0001` -> `20240000001`). It is deterministic, needs no lookup on the hot
    path, and is stable across rebuilds.
  - Any other advisory identifier (a sequence number of `10^7` or more, or a non-CVE id)
    gets an ordinal from `platform.exposure_advisory_ordinals`. That dictionary is
    sequence-backed and starts at `10^12`, so the two ranges cannot overlap.
- **`pkg_ord` and `pkgver_ord`.** These come from `platform.exposure_package_ordinals`
  (`package_identity_key -> bigint`) and `platform.exposure_package_version_ordinals`
  (`(package_identity_key, installed_version) -> bigint`), both sequence-backed.
- **`bitmap_hash` is never used.** It is a 32-bit hash: at about 77k distinct keys the
  probability of at least one collision is already about 50%, and the fleet has millions
  of package versions.
- **Allocation happens in the producer's transaction, before publish.** EventWriter maps
  and writes; it never allocates. When a new ordinal is allocated or a descriptive value
  changes, the publisher emits a dimension update (`exposure.dimensions.cve`,
  `exposure.dimensions.package`).

### Decision 5: An address dimension, and device ordinals stamped on flows

`serviceradar.exposure_device_addresses` is a Primary Key table keyed `(partition, ip,
device_ord, valid_from)`. Its columns are `valid_to`, `address_source` (inventory,
interface, agent address lease), `shared` (more than one device holds the address, or it
is a known VIP, anycast or VRRP address), `agent_attested` (the address appears in the
owning agent's address leases), and the prefix tags and `site` of the address. The tags
and site are stamped at publish time by the native prefix lookup, which a JDBC join cannot
express.

The publisher emits interval opens and closes on inventory address changes and on agent
address leases. Each publication is the complete current interval row (`valid_from`,
`valid_to`, flags, tags and site) with an `interval_seq` drawn per interval, and it is
applied, in StarRocks and in the flow tier, only when its `interval_seq` is greater than
the stored one, so a close that overtakes its open still converges.

The EventWriter flow tier keeps an in-memory, bounded validity history per address,
`(partition, ip) -> [(valid_from, valid_to, device_ord | shared)]`, fed by the same stream,
in the same way as the VIP map. Each endpoint is resolved against the intervals that cover
the flow's **observation time** (its start and end), never against whichever device holds
the address when the record arrives:

- exactly one device's interval covers the observation interval: `resolved`, with that
  ordinal;
- the address is shared during it: `shared`;
- more than one device held the address during it: `ambiguous`;
- no interval covers it: `unmapped`;
- the observation time is older than the retained history: `outside_history`, counted by a
  metric.

Only `resolved` stamps an ordinal. History is retained for the maximum accepted flow delay
(configured; default 15 minutes) plus the late window, and older closed intervals are
evicted. At ingest the tier stamps `src_device_ord`, `dst_device_ord`,
`src_device_resolution`, `dst_device_resolution`, `src_attribution_outcome` and
`dst_attribution_outcome` onto the flow row.

Device stamping participates in the same late window as attribution (*Late Binding Is
Bounded And Never Rescans Flows*), through the same watch and recompute mechanism, keyed by
`(partition, ip)` instead of by socket key. Address updates may lag the flow by up to the
60-second address freshness target, which is inside the 5-minute window:

- while a flow's window is open, the home shard keeps an address watch for each side;
- an address-validity update for a watched address within the window re-resolves that side
  at the flow's observation time, and a changed result is published as a decision update;
- a late ownership decision re-resolves the side with the same lookup and is published as a
  decision update;
- both kinds of update share the flow's one decision sequence, drawn by the home shard,
  which is the only writer of the flow's decision state. Each update carries the complete
  after-image of every column that sequence guards: for both sides the owner columns and
  owner context, attribution outcome and attribution source, device ordinal and device
  resolution, plus `attribution_finalized_early`. It never carries only the fields that
  changed, so whichever update has the higher sequence already contains every earlier
  change, and delivery in any order converges to the latest complete state;
- at the cutoff the stamp is final. An address update that arrives later and changes the
  holder for an already-final observation time does not rewrite flows; it is counted
  (`address_update_after_cutoff`).

The discrepancy candidate check and the network evidence delta both use the final stamp.
This avoids joining flows to a validity-interval table at query time. The StarRocks table
serves host evidence, discrepancy evaluation and investigation.

Example: device A holds `192.0.2.30` until 12:01, and device B from 12:01. A flow observed
12:00:00-12:00:40 that arrives at 12:02 resolves to A. A flow observed 12:00:30-12:01:30
is `ambiguous` and carries no ordinal. A flow observed at 12:01:00-12:01:02 that arrives
at 12:01:02, before B's interval arrives at 12:01:30, is first stamped with A; the address
update re-resolves it within the window and the decision update rewrites it to B.

Alternatives considered:

- **Joining `ocsf_devices.ip` through the catalog per query.** Rejected:
  - it holds the current address only, which is wrong under DHCP churn;
  - it is one address per device;
  - the join would run per flow row over JDBC.

### Decision 6: One observed-connection evidence set, with provenance

```sql
CREATE TABLE IF NOT EXISTS serviceradar.observed_connections_hourly (
  device_ord BIGINT NOT NULL, hour DATETIME NOT NULL, `partition` VARCHAR(128) NOT NULL,
  direction TINYINT NOT NULL,      -- 1 inbound (accepted), 2 outbound (connected)
  proto TINYINT NOT NULL, service_port INT NOT NULL,
  peer_ip VARCHAR(64) NOT NULL, peer_scope TINYINT NOT NULL,  -- internal, internet, unknown
  pkg_ord BIGINT NOT NULL,         -- 0 when unknown
  process_name VARCHAR(64) NOT NULL,  -- '' when unknown
  workload_key VARCHAR(256) NOT NULL, -- '' when none
  exporter_ord BIGINT NOT NULL,       -- exporter device ordinal; 0 for host evidence
  host_connections BIGINT SUM, host_bytes BIGINT SUM, host_packets BIGINT SUM,
  network_flows BIGINT SUM, network_bytes BIGINT SUM, network_unsampled_flows BIGINT SUM,
  first_seen DATETIME MIN, last_seen DATETIME MAX
)
AGGREGATE KEY (device_ord, hour, `partition`, direction, proto, service_port, peer_ip,
               peer_scope, pkg_ord, process_name, workload_key, exporter_ord)
PARTITION BY date_trunc('day', hour)
DISTRIBUTED BY HASH(device_ord) BUCKETS 16;
```

- **Evidence is monotonic.** A contact that happened never un-happens, so an Aggregate
  table is correct here, unlike for exposure state.
- **Two writers.**
  - The `host_connection_summaries` processor from #5753 additionally writes one evidence
    delta per summary row. Rows merged to the `service` or `overflow` level have no peer
    address; they become evidence with `peer_ip = ''` and `peer_scope = unknown`, are
    counted, and never match a threat or internet predicate.
  - The flow processor writes one delta per device-mapped side of each flow, once that
    side's device resolution is final at the late-window cutoff (Decision 5), so a
    corrected stamp never leaves evidence under the wrong device. Internal traffic
    therefore yields one row from each device's perspective. Deltas are pre-aggregated per
    batch by evidence key before Stream Load.
- **Provenance is computed when the table is read**, at the `(hour, device_ord, direction,
  proto, service_port, peer_ip)` grain, summing across process keys:
  - `host` when `host_connections > 0` and `network_flows = 0`;
  - `network` for the reverse;
  - `corroborated` when both are non-zero.
  Keeping the process in the key preserves per-process precision. Grouping without it
  stops an unattributed network row and an attributed host row from splitting into two
  provenances.
- **`peer_scope`** is classified at write time against the deployment's local CIDRs (the
  same source as flow `direction`). It records the classification as of observation time.
- **`service_port`** is the listener port for inbound contacts and the remote port for
  outbound contacts. Summaries keep ephemeral ports at their observed values; the evidence
  table drops them, because exposure questions are about services, not sockets. Full-key
  matching on ephemeral ports stays in `host_connection_summaries` for the evaluator.
- **Sampling.** `network_bytes` is scaled by the sampling rate.
  `network_unsampled_flows` counts records with `sampling_rate = 1`, so evidence strength
  is visible.

### Decision 7: Small dimensions through narrow catalog views

Two new flattened, read-only CNPG views are added. Each gets a column-scoped grant to
`serviceradar_starrocks_reader` and an entry in `CatalogAllowlist`:

| View | Columns | Purpose |
|---|---|---|
| `platform.exposure_device_catalog` | `device_ord, device_uid, hostname, device_type, vendor_name, partition, vlan_uid, owner_name, tag_site, is_available, agent_managed` | names, VLAN, owner, site tag and agent-managed flag for exposure rows. It covers only non-deleted devices with a non-tombstoned ordinal. `owner_name` is `owner->>'name'`, and `agent_managed` is derived from `ocsf_agents`. |
| `platform.exposure_device_tags_catalog` | `device_ord, tag_key, tag_value` | `tags.<key>` slicing. `jsonb_each_text` is flattened to text rows because JDBC cannot carry jsonb. |

These existing grants are reused unchanged:

- `ip_threat_intel_cache (ip, matched, expires_at, sources, max_severity)` and
  `threat_intel_indicators (indicator, expires_at)`, read only through the matched-set
  `native_query` the flow threat filters already use;
- `netflow_local_cidrs_catalog`.

Never catalog-joined per query: `endpoint_vulnerability_assessments`,
`endpoint_vulnerability_matches`, `endpoint_inventory_packages`, `endpoint_packages`,
`vulnerability_advisories`, `advisory_coordinates`, `device_fleet_ordinals`, `ocsf_agents`
and `alerts`. The large tables would be pulled whole, because aggregates and joins do not
push down through JDBC. The others are exposed only through the views above.

The device views are pulled whole per query (simple predicates may push down). That is
acceptable while they stay small. The capacity requirement sets the threshold above which
the device dimension is mirrored into StarRocks instead.

The migration follows `create_starrocks_catalog_reader_role`: grants are guarded on the
role existing, and the role is never given `LOGIN`.

### Decision 8: Threat intelligence covers host-observed peers

The IOC cache is populated from IPs seen in flows. In a host-only deployment no peer would
ever be looked up, and `contacted_threat` would be silently empty. Host-summary peers with
`peer_scope = internet` are therefore admitted to the same bounded lookup queue
(`NetflowSecurityRefreshWorker` / `FlowEndpointScan`), deduplicated against flow
endpoints. SRQL resolves the matched set exactly as the flow threat filters do: through a
`native_query` of matched, unexpired cache rows. Indicator detail stays in
`in:threat_intel_matches`.

### Decision 9: Listening processes resolve to packages

"Vulnerable listening process" requires a `(device, process) -> package identity` link.
#5752 resolves an executable to its owning package once per cache entry (Decision 18), and
attaches the inventory package reference to the current owner fields
(`FlowAttributionEvent` and `ProcessSnapshotEntry`). #5738 carries the same message onto:

- ownership lease owner records, so flows attributed through the index carry it;
- connection summary rows.

The publisher maps that reference to `pkg_ord` through the same identity derivation the
matcher uses (`EndpointPackageAssessmentIdentity`). Evidence rows carry `pkg_ord`, so
"listening and exposed" is an equality join on `(device_ord, pkg_ord)` between evidence and
facts. When ownership is unknown, `pkg_ord = 0`. Those rows are never claimed as exposed;
they appear only with `listening:true`, labelled `package_unknown`.

### Decision 10: Blast radius is a two-phase plan

The topology graph lives outside StarRocks. `in:exposure_blast_radius` therefore compiles
to a two-phase plan, which the SRQL runner executes in order:

1. The seed set is resolved from the exposure filters in StarRocks. It is capped at 500
   devices; above the cap the query returns an `InvalidRequest` asking for a narrower
   filter.
2. A bounded traversal runs in the topology graph with the seed uids bound as parameters.
   `depth` is 1-3 (default 2) and the result is capped at 5,000 nodes. Each row is
   `(device, hop, via_device, relation)`.
   - With `via:bgp`, prefixes announced by a seed, or with a seed as next hop, within the
     time window come from BMP events.
   - Devices whose addresses fall in those prefixes come from the address dimension, and
     are added with `relation = bgp_prefix`.

This follows the precedent of composite-result hostname frames, a second bounded query
scoped to a first query's result. Truncation is reported, never silent.

### Decision 11: History is a daily bitmap snapshot

`serviceradar.exposure_daily` is an Aggregate table keyed `(day, cve_ord, severity_rank,
kev)` with `devices BITMAP BITMAP_UNION`. A scheduled job writes it from the active facts
after UTC midnight. A day's snapshot is never modified afterwards, so the union is safe.

History filters are restricted to what the snapshot retains: `cve`, `severity`, `kev` and
device membership (`device_id`), plus the current-membership slices below. Package is
deliberately not retained: a package dimension would multiply the snapshot by the packages
per CVE, which does not fit the capacity target. Every other exposure filter (`package`,
`cvss_score`, `epss_score`, `exploit_available`, `agent_managed`, `hostname`) is rejected on
`in:exposure_history` as unsupported.

`serviceradar.exposure_transitions_log` (Duplicate Key, daily partitions) records every
transition. It provides newly exposed and remediated counts and mean time to remediate.

Trend slicing by site, VLAN or owner ANDs each day's bitmap with the slice's **current**
membership bitmap. This is documented as current membership (open question 3).

### Decision 12: Evasion and coverage-gap detection

**Inputs.**

- **Per-side attribution outcomes on flows.** These come from the ownership index
  (*Flows Are Attributed On Ingest By Key Lookup* and *Late Binding Is Bounded And Never
  Rescans Flows*), persisted per side by this change. A final `no_owner` on an address with
  presence is the starting point.
- **Host connection summaries.** These are defined by *Hosts Report Per-Process Connection
  Summaries As Evidence*: full keys including ephemeral ports, a per-agent cap per
  interval, and staged aggregation (`peer_ip`, `service`, `overflow`) above the cap.
- **Capture coverage attestations.** These are new. Each agent publishes one per summary
  interval, after all of its summary rows for that interval have been acknowledged.
  An attestation records:
  - `capture_mode` (`event_driven`, `polling` or `degraded`);
  - `netns_scope` (`host` or `all`);
  - the attested address-set digest;
  - kernel event loss and ownership events shed by the event budget, by reason;
  - summary rows emitted and the highest aggregation level reached;
  - maximum publish lag and backpressure;
  - restarts within the interval;
  - `clock_offset_ms` and clock sync state;
  - `complete`, which is true only when every loss and shed counter is zero, no summary
    was aggregated beyond `peer_ip`, the mode is `event_driven`, no restart or
    backpressure occurred, and lag is within bound.

  A shed lease renewal voids the claim even though it does not truncate the lease's
  validity: a lease that expires at `last_seen + ttl` before its socket closes leaves later
  flows `no_owner`. Aggregation to `service` or `overflow` voids it because the merged rows
  have lost the peer address that a match needs.

**`network_only` (evasion) pipeline.**

1. The flow's home shard publishes a candidate only when a side's decision is still
   `no_owner` at the late-window cutoff (default 5 minutes after the flow). Flows marked
   `attribution_finalized_early` and flows with agent-provided attribution never produce
   candidates. The side's device resolution at the flow's observation time must be
   `resolved`, to exactly one agent-managed device with `agent_attested = true`. Candidates are deduplicated per
   `(device_ord, peer, port, proto, minute)`.
2. The sharded evaluator holds each candidate until the evaluation point of its hour (the
   hour containing `flow_end + tolerance`, below) has passed, attestations cover `[flow_start - tolerance, flow_end +
   tolerance]`, and the host-summary stream for that agent has been consumed past that
   range. If the attestations do not arrive within a deadline after the evaluation point
   (default 10 minutes), the candidate is recorded as suppressed with `coverage_unknown`.
3. The evaluator checks the controls below, in order. The first one that fails records a
   suppression with its reason.
4. It looks for a matching host connection in `host_connection_summaries`: same agent,
   protocol and full endpoints after translation (rows merged to the `peer_ip` level match
   on addresses and local port only); the interval overlaps within the tolerance. A match
   means the signal is not raised (`host_matched`).
5. It scores and publishes the signal.

**False-positive controls.** Each one is a requirement with scenarios.

| Control | Rule | Suppression reason |
|---|---|---|
| Sampling | A signal needs at least one unsampled record (`sampling_rate = 1`) that contains host-originated packets. sFlow and other sampled-only evidence is recorded and never signalled. | `sampled_only` |
| Unanswered traffic | Inbound-only packets, or a host response that is only TCP RST or ICMP unreachable, mean the kernel rejected the traffic and no socket existed. | `unanswered_inbound`, `kernel_reject` |
| Coverage mode | `capture_mode` is not `event_driven`. Polling misses short-lived sockets, so it never supports a claim. | `not_event_driven` |
| Agent health | Missing attestation, `complete = false`, kernel loss, budget shedding, a restart, lag over bound, backpressure, a summary count mismatch between the attestation and what was received, or the ownership shard warming. | `coverage_incomplete`, `agent_unhealthy`, `summary_incomplete`, `index_warming` |
| Address translation | The side's address must be the host's own address, or must resolve through the VIP map or node SNAT to exactly one backend. Exporters marked as outside NAT never source candidates on their own. | `unresolved_translation` |
| Clock skew | `tolerance = base (5 s) + abs(agent clock_offset) + exporter skew estimate`. Unknown sync state, or skew above the maximum (30 s), suppresses. | `clock_unbounded` |
| Shared or multi-homed addresses | Addresses held by more than one device in the window (VIP, anycast, VRRP, reused DHCP) are not attributed to one host. An address missing from the agent's attested set is not covered. | `shared_address`, `address_not_attested` |
| Network namespaces | A pod or container address requires `netns_scope = all`. | `netns_not_covered` |
| Spoofing (optional) | When the exporter interface's segment is known, a host-originated record arriving on another interface is suppressed. | `ingress_mismatch` |

**Confidence for `network_only`.** `confidence = E x T x M`. Coverage is a gate, not a
factor.

- `E` (evidence) is 1.0 when the host-originated unsampled record carries payload (PSH or
  more than 1 KiB), and 0.9 when it carries ACK only.
- `T` (translation) is 1.0 for a direct address and 0.9 for a single-backend VIP or SNAT
  resolution.
- `M` (temporal margin) is 1.0 when the overlap sits at least one tolerance away from any
  attested-interval edge, and 0.9 otherwise.

The `network_only` incident threshold defaults to 0.85. Signals below the threshold are
stored and queryable but do not alert. The score is a pure function of stored inputs, so
it can be recomputed in tests and investigations.

**Evaluation point.** Both directions use one evaluation interval, the UTC hour, and are
evaluated together at one point per hour `I` ending at `e`:
`E(I) = max(e + exporter active timeout, e + maximum accepted flow delay + late window) +
60 s`. That is the later of the exporter's last possible export and the late-window cutoff
of every flow observed in `I`, plus the network-evidence write target. One read of the host
and network evidence taken at `E(I)` serves both the `network_only` candidates of that
hour and its `host_only` evaluation. With the defaults
(15-minute maximum flow delay, 5-minute late window) an hour is evaluated about 21 minutes
after it closes. Example: a contact at 12:59:50 is reported by the host at 13:01; the flow
is ingested at 13:00:30 and its network evidence is written after its cutoff at 13:05:30.
Hour 12 is evaluated at about 13:21, sees both, and records no gap.

**`host_only` (coverage gap) evaluation.** This runs hourly, at the evaluation point of
each closed hour, against `observed_connections_hourly`. It is opt-in per
expected-coverage rule (a CIDR or prefix tag mapped to a set of exporters). It selects
contacts with `peer_scope = internet` and `host_connections > 0` for devices covered by
a rule that have no network evidence from the rule's own exporters (`exporter_ord` in the
rule's set). Evidence from any other exporter does not satisfy the rule.

- A gap requires the exporter to have been healthy for that hour: records were received,
  and none arrived later than the maximum accepted flow delay.
- Under sampling, the expected probability of having seen the contact,
  `1 - (1 - 1/N)^host_packets`, must be at least 0.999. Without host packet counters,
  sampled exporters are skipped.
- Severity is low. Incidents are grouped per `(device or rule, exporter)`.

**Confidence for `host_only`.** There is no network record and no required attestation, so
`network_only`'s factors do not apply. Exporter health, the expected-coverage rule match
and the sampling expectation are gates. `confidence = H x X x P`:

- `H` (host evidence strength) is 1.0 when the contact carries at least 10 host packets and
  1 KiB of host bytes, and 0.8 otherwise;
- `X` (exporter position) is 1.0 when the rule marks the exporter as on the internet path
  for the covered prefix and it is unsampled, 0.9 when it is on the path and sampled, and
  0.8 when its position is not stated;
- `P` (persistence) is 1.0 when the same `(device, rule, exporter)` gap was also signalled
  in the previous closed hour, and 0.7 for a first hour.

The `host_only` incident threshold defaults to 0.75, so a single-hour gap stores a signal
but does not alert, and a gap that persists on a known path does. The score is a pure
function of the stored hourly evidence, rule and exporter health rows.

**Output.** Each signal and each suppression is published on `exposure.discrepancies`.
EventWriter writes `connection_discrepancies` (suppressions included, with their reason)
and an OCSF Detection Finding for signals only. The finding is
`class_uid 2004`, with a stable `finding_info.uid` fingerprint of `(kind, device_uid)` for
`network_only` and `(kind, device_uid or rule, exporter)` for `host_only`.
`StatefulAlertEngine` groups the findings into incidents; occurrences update the incident
and do not create new alerts.

### Decision 13: Freshness model

| Path | Target (p99) |
|---|---|
| Assessment commit -> fact visible | <= 120 s (outbox relay <= 10 s, EventWriter batch <= 30 s, Stream Load <= 30 s, margin) |
| Fact -> bitmap views | <= 180 s (60 s refresh plus a refresh duration of <= 60 s) |
| Inventory address change or address lease -> address dimension and flow-tier validity history | <= 60 s |
| Summary interval close -> host evidence visible | <= 120 s |
| Flow's late-window cutoff -> network evidence visible | <= 60 s |
| Hour evaluation point `E(I)` (Decision 12) -> discrepancy record | <= 300 s; incident <= 60 s later |
| UTC midnight -> daily snapshot | <= 15 min |

The upstream bound from an inventory scan to a transition belongs to #5748 and is not
restated here. Every SRQL response carries `as_of` per source: facts, views, evidence and
snapshots.

### Decision 14: Rebuild and reconciliation

- **Snapshot.** Used on a fresh install, after a warehouse restore, or after a
  reconciliation mismatch. The fence is the database snapshot the publisher read, which is
  commit-ordered; a sequence threshold is not, because a transaction can draw a sequence
  below the threshold and commit after the snapshot was read.
  - The publisher opens generation `G` in one read-only `REPEATABLE READ` transaction whose
    first statement records `V = pg_current_snapshot()` (`xmin`, `xmax`, `xip`). Every
    read in that transaction sees exactly `V`.
  - It emits every actionable assessment visible in `V` as a `SNAPSHOT` upsert carrying the
    row's complete after-image, last `transition_seq` and `transition_xid`. It also emits
    a `SNAPSHOT` watermark for every other fact key known to CNPG in `V`, copied from the
    retained publication (Decision 24): non-actionable assessment rows and
    `platform.exposure_fact_watermarks` for deleted keys. That table holds the key, the
    `resolved` state, the **new** sequence that the deleting transaction drew, and the
    retained terminal publication. It also emits `RETIRED(device_ord, retired_seq)` for every tombstoned
    ordinal, plus the latest lifecycle state and sequence for restored ordinals,
    preserving the last retirement watermark (Decision 23). Assessment after-images
    carry their lifecycle sequence. It then emits `SNAPSHOT_END(G, V)`.
  - A snapshot row is compared with the stored row on sequence, state and content.
    A greater sequence applies the source after-image. An equal sequence with equal
    state and equal content changes only `snapshot_generation`. An equal-sequence state or content
    mismatch is counted and repaired through a new source transition, drawn under the
    full fact-key serialization after re-reading the current source state and locking
    any existing assessment. Repair never changes content under an existing sequence.
    The source watermark path owns repairs for deleted assessment keys; Decision 20
    covers keys with neither an assessment nor a watermark.
  - Example (deletion): an active fact at sequence 10 has its assessment row deleted; the
    deleting transaction draws sequence 11 and records `resolved` at 11. A warehouse still
    holding the fact active at 10 receives the watermark at 11, which is greater, so the
    fact ends resolved.
  - The outbox keeps relaying live transitions throughout. A transition whose
    `transition_xid` is not visible in `V` (in flight or committed after `V` was taken) is
    applied normally whenever it arrives. Its per-row sequence is above the one the
    snapshot read, because it was drawn under the fact-key serialization after the
    visible change committed, so the merge condition lets it win in either arrival order.
  - On `SNAPSHOT_END`, rows with `snapshot_generation < G` whose `transition_xid` is
    visible in `V` (`xid < xmin`, or `xid < xmax` and not in `xip`) are reconciled
    through the same source-locked repair path with a new sequence when resolution is
    still required. A source recheck protects a change committed after `V`. If neither
    an assessment nor a watermark exists, the repair records a terminal watermark and
    outbox transition atomically under the same fact-key serialization as creation,
    with a sequence greater than the stored warehouse fact (Decision 20). Rows last
    written by a transition not visible in `V` are left
    as they are. Live transitions write their complete after-image except
    `snapshot_generation`, which only the snapshot manages, so a delayed redelivery of a
    transition the snapshot already read does not make a snapshot-touched row look
    untouched.
  - Example (warehouse restore): the restored warehouse holds a fact active at sequence 9,
    CNPG resolved it at sequence 11 (visible in `V`), and active sequence 10 is still
    awaiting redelivery. The snapshot writes the watermark at sequence 11, and the
    redelivered sequence 10 is rejected, in either arrival order, however long it was
    delayed.
  - Example (in flight): a resolving transaction draws sequence 41 and is still in flight when `V` is
    taken. The snapshot reads the row as active with sequence 40 and upserts it. The
    resolution commits and arrives with sequence 41, before or after the upsert, and the
    fact ends resolved.
- **Per-device reconciliation.** A daily job compares, per device between CNPG and
  StarRocks, the actionable count and an order-independent digest over each fact's
  `(cve_ord, pkg_ord, transition_seq)` and a content hash of the actionable attributes
  named by *Exposure Is Rebuildable And Reconciled Against The Assessment Store*, so a lost update that
  changes only an attribute is detected as well as a changed membership.
  Mismatched devices get a per-device snapshot, fenced the same way and scoped to the
  device. Mismatch counts are exported, so the check can fail visibly.

### Decision 15: Exposure requires StarRocks

The exposure entities return `{:error, :starrocks_required}` without StarRocks, and the UI
reports that state. This extends the approved exception for flow and process-attribution
reads (`AGENTS.md`). The reasons:

- Host connection summaries and coverage attestations belong to the attribution family,
  like ownership leases.
- The evidence and traffic joins need flows, which are StarRocks-only.
- Nothing is lost on a CNPG-only installation: assessments stay in CNPG, and use case 1 is
  still answered there by `in:devices cve:` and `in:endpoint_vulnerability_assessments`.

The product owner [approved this requirement on 2026-10-18](https://github.com/carverauto/serviceradar/issues/5745#issuecomment-6255360407).
The StarRocks-required exception is recorded in `AGENTS.md` (task 0.9).

### Decision 16: How the showcase queries compile

| Use case | SRQL | Shape of the StarRocks plan |
|---|---|---|
| 1. Devices exposed to CVE-X | `in:exposure cve:CVE-2024-0001 sort:hostname:asc limit:200` | `exposure_facts` range scan on `cve_ord = 20240000001 AND state = 1`, joined to `exposure_cve_dim` and the device catalog view |
| 1. Count by site | `in:exposure cve:CVE-2024-0001 stats:"count_distinct(device_id) as hosts by site"` | `exposure_cve_devices_mv` bitmap for the CVE, ANDed with per-site bitmaps built from the address dimension |
| 2. KEV or high EPSS with IOC contact | `in:exposure kev:true contacted_threat:true time:last_24h limit:100`; `in:exposure epss_score:>=0.5 contacted_threat:true time:last_24h` | KEV device bitmap (or the EPSS filter on the CVE dimension) -> `observed_connections_hourly` with `device_ord` in the set, `hour` in the window, and `peer_ip` in the matched IOC set (`native_query`) |
| 2. The contacts behind it | `in:observed_connections exposure_kev:true threat_matched:true time:last_24h sort:last_seen:desc limit:100` | the same, at evidence grain, with provenance |
| 3. Listening, exposed, reached from the internet | `in:exposure listening:true inbound_internet:true severity:critical time:last_24h sort:cvss_score:desc limit:100` | facts with `state = 1, severity_rank = 4` joined to evidence on `(device_ord, pkg_ord)` with `direction = inbound, peer_scope = internet` |
| 4. Blast radius | `in:exposure_blast_radius cve:CVE-2024-0001 depth:2 via:(topology,bgp) limit:500` | phase 1 seeds from facts; phase 2 bounded graph traversal plus BMP prefixes -> address dimension |
| 5. Slicing | `in:exposure severity:critical stats:"count_distinct(device_id) as hosts by owner"`; `in:exposure kev:true tag:dmz`; `in:exposure vlan:120`; `in:exposure namespace:payments time:last_24h` | bitmap AND with the slice bitmap, or a join to the catalog view, the address dimension or evidence |
| 6. Trend | `in:exposure_history kev:true time:last_90d stats:"count_distinct(device_id) as hosts by day"` | `exposure_daily` with `bitmap_union_count` per day |
| Evasion triage | `in:connection_discrepancies kind:network_only confidence:>=0.85 time:last_24h sort:confidence:desc` | `connection_discrepancies` scan, by partition |
| Pivots | `in:attributed_flows dst_device_id:sr:00000000-0000-4000-8000-000000000001 attribution_outcome:no_owner time:[...]`; `in:agent_coverage agent_id:agent-01 time:[...]`; `in:exposure_incidents status:active kind:network_only` | flow rows by stamped ordinal; the coverage timeline; alert incidents |

### Decision 17: Authorization

| Entity | Permission |
|---|---|
| `in:exposure`, `in:exposure_history`, `in:exposure_blast_radius` | `devices.view` |
| `in:observed_connections`, `in:connection_discrepancies`, `in:agent_coverage` | `observability.netflow.view` and `devices.view` |
| `in:exposure_incidents` | `observability.alerts.view` and `devices.view` |
| Traffic predicates on `in:exposure` (`contacted_threat`, `inbound_internet`, `listening`, `provenance`, `namespace`) | additionally `observability.netflow.view` |
| Exposure pivot filters on `in:flows` and `in:attributed_flows` | additionally `devices.view` |

Every entity is listed in the `EntityAccess` map under one canonical name; the new
entities have no aliases. Unknown-entity passthrough must not skip the gate.

### Decision 18: Executable ownership is resolved by netprobe, by inode

This settles how #5752 implements Decision 9.

**Privilege.** Netprobe starts as root to load eBPF and then drops to the service user.
Without a capability, that user cannot read `/proc/<pid>/exe` or `/proc/<pid>/root` of a
process owned by another user, and those are the listeners that matter (sshd, web servers).
Netprobe therefore keeps exactly one capability after the drop: `CAP_SYS_PTRACE`, in the
permitted and effective sets only. It sets `PR_SET_KEEPCAPS` across `setuid`, reduces the
permitted and effective sets to `CAP_SYS_PTRACE`, leaves the inheritable and ambient sets
empty, and clears `PR_SET_KEEPCAPS` again. The service unit adds `CAP_SYS_PTRACE` to its
bounding set and not to its ambient set. Capabilities are per thread, and netprobe's tokio
workers and eBPF reader threads start before the drop and lose all capabilities in the
`setuid`. The dropping thread therefore keeps `CAP_SYS_PTRACE` and spawns one dedicated
executor thread, which inherits it and runs every ownership resolution; no other thread
holds it. Netprobe uses it only for ptrace-read access to procfs.

**Resolution.** For a process, netprobe stats `/proc/<pid>/exe` for the executable's
`(dev, inode)`, which works for a deleted or replaced binary. It reads the package
databases inside the process's own root (`/proc/<pid>/root`), so a containerized process
resolves against its image's package database. `source_scope` is `host` for a process in
the host root and `container` otherwise. Inventory rows are host-scoped, so a containerized process's reference deliberately never
joins host exposure facts and stays `package_unknown` until container packages are
inventoried; this is intended, not a miss. Supported databases are dpkg (`status` plus
`info/*.list`), apk (`installed`) and the rpm sqlite backend (`rpmdb.sqlite`). rpm keeps its
write-ahead log after checkpoints, so the reader applies the log's committed frames over the
main file, as a SQLite reader does; a non-empty log is not a pending state. The older rpm
BerkeleyDB and NDB backends are reported as `UNSUPPORTED_DB` only when no supported database
is present; a root with `rpmdb.sqlite` next to a leftover BerkeleyDB `Packages` file reads
the sqlite database. A package owns the executable when one of its listed paths, resolved
inside the process root with directory symlinks followed but never allowed to leave that
root, has the executable's `(dev, inode)`. A listed path whose final component is itself a
symlink owns nothing; the file it points to is listed by its own package. Comparing inodes,
not path strings, handles merged `/usr` layouts and other directory symlinks. It also means that a binary whose package was
upgraded or removed while the process kept running is never attributed to the package that
now owns its path.

**Cost.** Results are cached per (process root, executable `dev`, `inode`). An entry is valid
while the file's mtime and size and that root's package-database state are unchanged; a
reused inode or a package change in that root re-resolves it. A read where the kernel
reports the executable deleted neither uses nor stores a cache entry. The cache and the number of
cached package-database indexes are bounded. Resolution runs on netprobe's existing budgeted
process-metadata path, so it happens once per cache entry and never once per connection or
per event.

**States.** `ExecutableOwnership.resolution_state` is the first of these that applies, in
this order:
1. `NOT_PERMITTED`: procfs or the root denied access.
2. `UNKNOWN`: the process exited; or a procfs or root read failed other than by an access
   denial; or the kernel reports the executable deleted (its file was
   unlinked or replaced, for example by a package upgrade or removal, while the process kept
   running, whether or not a package ever owned it); or the root has no package database; or
   a database was unreadable, changing or truncated.
3. `UNSUPPORTED_DB`: no supported database is present, and an unsupported one is.
4. `RESOLVED`: a supported database lists a path with the executable's `(dev, inode)`.
5. `NOT_FOUND`: the executable is still linked on disk, every supported database present
   was read completely, and no listed path has its inode, even if an unsupported database is
   also present.

A closed `detail` vocabulary names the reason. Only `RESOLVED` carries a package. No state
is ever filled in from the process name or the command line.

**Wire.** `ExecutableOwnership` in `proto/agent/netprobe/v1` carries:
- the resolution state and detail;
- the package identity fields `EndpointPackageAssessmentIdentity` uses: `source_scope`,
  `package_type`, `package_manager`, `namespace`, `release`, `ecosystem`,
  `binary_package`, `source_package` and `architecture`;
- the installed version;
- provenance: the resolver, the executable path, `dev` and `inode`. The resolver names
  which database answered (`dpkg`, `rpm` or `apk`) and is distinct from `package_type`
  (`deb` for dpkg).

Netprobe fills the identity fields from the database it read and from the root's
`os-release`, mirroring the live endpoint inventory producer, the ScaLibr add-on
(`go/pkg/scalibrinventory`), whose package URLs come from osv-scalibr. Those URLs carry a
namespace (the os-release `ID`; rpm maps `sles` to `suse` and `mariner`/`azurelinux` to
`azurelinux`) and a `distro` qualifier, so core's canonicalization keeps them; its
debian/alpine/rpm namespace default applies only to a package URL without a namespace.

| Database | `package_type`, `package_manager`, `ecosystem` | `namespace` | `release` | `binary_package` / `source_package` | `architecture` | Installed version |
|---|---|---|---|---|---|---|
| dpkg | `deb`, `dpkg`, empty | os-release `ID`, else `linux` | `VERSION_CODENAME`, else `VERSION_ID` | package name / the `Source` field's package name when present, else the binary name | `Architecture` | the status `Version` |
| apk | `apk`, `apk`, empty | `ID`, else `alpine` | `VERSION_ID` | the lower-cased package name for both (apk URLs carry `origin`, not `source`) | `A` | the installed version |
| rpm | `rpm`, `rpm`, empty | `ID` mapped `sles` to `suse` and `mariner`/`azurelinux` to `azurelinux`; empty when `ID` is unset (no default) | `<raw ID>-<VERSION_ID, else BUILD_ID>` when `ID` is set; the version alone when `ID` is empty; empty when both version fields are empty | package name / the binary name (rpm URLs carry `sourcerpm`, not `source`) | the rpm arch | `<version>-<release>` |

`architecture` is empty only when the database records none, and `source_scope` follows the
resolution rule above. `ecosystem` is empty because the endpoint inventory stores no
ecosystem for OS packages, so the matcher hashes it as absent.

Netprobe does not compute the `pkgid:v1:` key. Core does not match the reference against inventory rows. It derives
`package_identity_key` by applying `EndpointPackageAssessmentIdentity` to the reference's
identity fields, the same derivation the matcher applies to inventory packages. Before
hashing, core treats every blank identity field (for example an empty `namespace`,
`release`, `architecture`, `ecosystem` or `source_package`) as the absent component (nil),
as the matcher's package-URL parse does. The
installed version is evidence and is not part of the key, so an upgrade does not change the
key. A reference whose derived key matches no assessment simply has no exposure facts.

**Placement.** Until #5738 lands the lease and summary messages of
`stream-flow-attribution-via-ownership-index`, netprobe attaches `ExecutableOwnership` to
`FlowAttributionEvent` and `ProcessSnapshotEntry`, the current owner fields. Core carries it
through the existing attribution path. #5738 moves the same message onto lease owner records
and connection summary rows. Neither step adds a CNPG table.

Language package managers (pip, npm and similar) are not consulted. They own scripts, not
the executable the kernel runs, which is the interpreter from an OS package.

### Decision 19: Sequence replay and warehouse ordinal storage

The product owner approved both adjustments after reviewing the Section 0 spike:

1. Permit identical equal-sequence replay. Each fact/sequence identifies an immutable
   producer after-image; any changed content requires a new sequence. StarRocks
   `merge_condition = transition_seq` accepts greater or equal values, so it rejects
   stale delivery but does not itself detect conflicting equal-sequence content. The
   producer owns that invariant. Live loads preserve snapshot markers using row-mode
   partial updates that name every event-owned column and omit `snapshot_generation`.
   Snapshot repair and finalization cannot reuse a sequence for changed content; they
   re-read the source under its lock and publish a new transition, as the epic's repair
   note requires. Compaction changes only terminal storage payload; identical terminal
   replay may restore that payload without changing exposure membership.
2. Use `BIGINT` for every warehouse device/exporter ordinal: facts, addresses, evidence,
   retired ordinals and flow stamps. Source values remain in `1..4294967295`, with `0`
   allowed only where the schema explicitly defines a sentinel. Producers and ingestion
   boundaries enforce those bounds; the wider storage type does not expand the identity
   space. Bitmap values remain collision-free integers.

A follow-up scratch test exercised actual conditional row-mode Stream Load with
`2147483648` and `4294967295`. Both were stored exactly and remained distinct bitmap
members. New rows received snapshot generation 0. Newer, stale and identical replay
loads all preserved an existing generation 7. An identical terminal replay after
payload compaction stayed resolved; a changed after-image with a new sequence applied.
All assertions passed, and the disposable database was dropped and its absence checked.
The scale test was then repeated with `BIGINT` keys at 50 million rows, including
the synthetic JDBC join, bitmap counts and full refreshes described below.

### Decision 20: Missing-source snapshot repair

The product owner approved publishing a new terminal watermark when a snapshot finds
an active warehouse fact but a current CNPG recheck finds neither an assessment nor a
deletion watermark. The repair records the watermark and complete terminal outbox
after-image in one CNPG transaction. It serializes on the full fact key with assessment
creation as well as update/deletion, including when no assessment row exists. A row
lock on an absent assessment is not sufficient.

After obtaining that serialization, re-read the assessment and watermark. If a source
row now exists, use its current state through the normal repair path. Otherwise record
`resolved` under a new transition sequence greater than the stored warehouse fact's
sequence and publish that watermark through JetStream. Never rewrite the warehouse
fact at its old sequence. Concurrent creation must obtain the same serialization and
draw a later sequence, so it wins in either
delivery order. Re-creation removes the terminal watermark in the same transaction as
the new assessment transition. The repair carries its producing transaction's
`transition_xid`, like any other transition.

Migration `20261025185606` implements this source repair under Decision 24, including
fact-key serialization. Snapshot invocation, finalization and reconciliation remain
task 1.6. The repair contract for a stored terminal is the exposure-intelligence
requirement *Exposure Is Rebuildable And Reconciled Against The Assessment Store*.

### Decision 21: Build the assessment foundation independently

On 2026-10-24 the product owner directed work to stop codec tuning and continue
the exposure workstream, accepting the proposed sequencing of the independent
assessment foundation ahead of the remaining attribution gates. Tasks 1.x may
proceed using the delivered assessment outbox and ordinal dictionaries. The
decision named tasks 0.3-0.5 as the gates on traffic evidence integration and
launch. Task 0.3 has since landed; tasks 0.4 and 0.5 still gate that work.
No capacity threshold, evidence requirement, or launch scope is waived.
Snapshot and reconciliation must pass before exposure SRQL entities become
available.

Migration 0032 creates the four tables in task 1.2. The fact key and columns follow
Decision 2, including BIGINT device ordinals and the default snapshot marker from
Decision 19. The CVE dimension maps `cve_ord` to the advisory identifier and nullable
EPSS score. The package dimension is keyed by `pkgver_ord`, carrying `pkg_ord`,
package identity, display name and installed version: different installed versions
must coexist across devices. Both dimensions carry their last update time. Fixed
versions are assessment-specific and are not stored as a package-wide attribute.

The daily Duplicate Key history carries transition identity, state, exposure and
resolution times, and the complete transition JSON. Its initial partition retention
is 365 daily partitions; wiring the database-backed history retention setting remains
task 3.4.
Current facts and dimensions have no partition expiry. This migration does not
start ingestion or expose a query entity; processors, retirement handling,
snapshot repair and reconciliation remain separate tasks.

### Decision 22: Versioned CVE and package dimension publication

Approved by the product owner on 2026-10-24. This settles the remaining CVE/package parts
of tasks 1.3 and 1.4; the address dimension remains in tasks 2.1 and 2.2.

**Why a contract is needed.** Migration 0032 gives both dimensions `updated_at`
but no sequence column. Two changes in the same timestamp precision, or an older
message delivered after a newer one, cannot safely use arrival order to select
the current metadata. Assessment transitions also omit package display names
and EPSS, and an EPSS-only change does not produce an assessment transition.
Deriving dimensions solely from the transitions would therefore be incomplete.

**Publication and ordering.** Keep durable producer-side dimension records in
CNPG, keyed by dimension kind and ordinal, containing their last complete
after-image and sequence. These are dictionary publication state, not an
exposure projection or a query fallback. Serialize creation and descriptive
changes on that full key, including the absent-row case. A changed after-image
draws a new value from `platform.exposure_transition_seq` and persists that
value and an outbox row in the same transaction. An unchanged after-image does
not allocate a new sequence. A rollback leaves neither the changed publication
state nor its message. Retry and rebuild replay the stored payload and sequence;
changing content under the same sequence is forbidden.

**Source values.** Register the CVE and package-version dimensions in the
assessment-producing transaction after their ordinals have been allocated.
Also capture changes to the assessment's package descriptive fields even when
they do not change exposure membership. The package row contains `pkgver_ord`,
`pkg_ord`, `package_identity_key`, `installed_version`, and `package_name`.
Use the assessment's nonblank package name, then its nonblank binary package
name, then the identity key as the display fallback. Later serialized
descriptive changes replace that label; installed versions retain separate
rows. Deleting the last assessment does not delete its dictionary description.

A CVE row contains `cve_ord`, `cve_id`, and nullable `epss_score`. Initial
registration supplies a null score until enrichment and never clears an
already enriched score. A daily producer refresh uses the existing
`AdvisoryFeeds.CvePriority` policy over current, enabled advisory sources and
publishes only changed values for registered CVEs. Missing or withdrawn EPSS
becomes an explicit null under a new sequence. Zero remains a valid score;
only finite scores in the inclusive range 0 through 1 are published. No new
feed download or assessment rewrite is introduced. A failed source read must
fail the refresh, not masquerade as an empty source and clear scores.

**Transport and ingestion.** Publish schema-version-1 complete after-images on
`exposure.dimensions.cve` and `exposure.dimensions.package`, with
`transition_seq` and UTC `updated_at`. A producer-owned `EXPOSURE_DIMENSIONS`
stream captures those two subjects, using file storage, one replica, limits
retention, discard-old, a seven-day maximum age and a two-minute duplicate
window. Its separate byte budget follows the existing transitions profile:
1 GiB small, 2 GiB medium, 8 GiB large and 32 MiB tenant-2g. The relay removes an
outbox row only after PubAck, uses a message id derived from its stored sequence,
and reports pending age with a ten-minute health threshold. Stream expiry or
byte eviction requires the rebuild/reconciliation path; PubAck alone does not
prove warehouse delivery.

Add `transition_seq BIGINT NOT NULL DEFAULT 0` to both warehouse dimensions in
a new migration. EventWriter attaches to the producer-owned stream and applies
complete rows with `merge_condition = transition_seq`. Older updates cannot
overwrite newer values; identical equal-sequence replay is allowed. The
processor allocates no identifiers and reads no CNPG data. Failed or filtered
loads fail the batch. It is enabled only with StarRocks. Helm grants core
publication and EventWriter consumption for the two subjects.

Existing dictionaries and assessments are seeded through the snapshot work in
task 1.6. That work must include dimension replay and reconciliation, including
explicitly cleared scores, before exposure queries are enabled. This slice
does not claim warehouse restore or full exposure readiness.

**Required evidence.** A rolled-back source change publishes nothing; a failed
publish retains its exact payload; new and changed descriptions publish once;
two installed versions coexist; EPSS can change and clear without changing an
assessment; duplicate and reversed delivery preserve the latest dimension;
and a missing StarRocks backend never writes a CNPG projection.

### Decision 22 implementation evidence (2026-10-24)

Migration `20261024210000` adds source-transaction dimension publication state,
registration triggers and the acknowledged outbox. The daily refresh uses the
existing priority source; shared relay transport preserves immutable retries
and outbox health reporting. Warehouse migration `0033` adds sequence columns,
and EventWriter loads complete CVE/package rows with conditional merge.

The remote full unit run passed with 459 tests passing and two skipped
([BuildBuddy invocation](https://carverauto.buildbuddy.io/invocation/d88b4fed-1888-4dad-8290-88c580edba84)).
The new consumer tests failed before implementation at the routing boundary,
then passed with the producer-owned stream configuration, payload validation,
load headers, retry labels and failed/filtered-load behavior. Strict OpenSpec
validation also passed. Source-transaction, EPSS refresh, PubAck retry and
concurrent creation/update cases extend the existing serial database suite;
the hosted integration run is still required.

An isolated synthetic warehouse probe applied production migrations 0032 and
0033 and exercised actual Stream Load: reversed delivery and identical replay
preserved the newest CVE score, a newer explicit null survived older replay,
and separate package versions retained their newest descriptions. The scratch
database was removed and its absence rechecked. This proves the warehouse
boundary; it does not claim deployed end-to-end product delivery. Dimension
bootstrap and recovery remain task 1.6, and address evidence remains 2.1/2.2.

### Decision 23: Restore exposure without changing fleet identity

Approved by the product owner on 2026-10-24. This decision changes the unconditional permanent-retirement rule in Decisions 2
and 4; it does not change who may restore a device.

**Conflict found during implementation planning.** Fleet identity deliberately
retains the same ordinal across deletion and legitimate restoration, including
an explicitly authorized unmerge. The existing integration test
`endpoint_inventory_fleet_ordinal_test.exs`, scenario "delete and legitimate
restore retain identity while stale merge restores are denied", asserts that
behavior. `ensure_device_fleet_ordinal` clears `tombstoned` on restoration and
also sets it when `is_active` becomes false. A permanent exposure denylist keyed
only by that ordinal would therefore hide a restored device forever. Allocating
a different fleet ordinal would change the shared identity contract, including
other bitmap consumers, and is outside this exposure slice.

**Behavior.** Preserve the fleet ordinal and make exposure retirement
reversible only by an explicit, newer source lifecycle transition:

- A live-to-tombstoned change publishes `device_retired` at a new sequence `R`
  in the same source transaction. No assessment after-image is published for
  that ordinal while it remains tombstoned. Assessment storage and its CNPG
  query surfaces continue to work.
- An already-authorized tombstoned-to-live change publishes `device_restored`
  at a new sequence `U > R`, in that source transaction. It does not replay
  pre-retirement assessment messages as current. Current actionable assessments
  are re-read and published under fresh sequences greater than `U`. This
  resynchronization must be durable, bounded and included in snapshot readiness;
  restoration alone is not evidence that exposure has caught up.
- Source lifecycle publication and assessment publication serialize per device,
  in addition to the full fact-key serialization in Decision 20. A retirement
  sequence exceeds every assessment sequence published in the earlier lifecycle.
  Rollback leaves no lifecycle state change or outbox message. Repeated writes
  of the same lifecycle state do not allocate new sequences.
- Each assessment after-image carries its device lifecycle sequence, initially
  zero before the first lifecycle change. The warehouse keeps the latest
  lifecycle state and sequence and the last retirement watermark permanently.
  Restoration advances this record; it never deletes the retirement evidence.
  Device lifecycle messages travel through the existing transitions outbox and
  JetStream stream, not a direct warehouse write.
- The ingestion boundary drops and counts facts from older lifecycles, including
  keys never previously delivered. Facts from a newer lifecycle whose marker
  has not arrived are deferred for retry, not acknowledged and lost. Only a
  current live lifecycle accepts its after-images. Reordered retirement and
  restoration markers cannot roll the lifecycle backwards. Identical replay
  remains allowed; changed content always needs a new sequence.
- Applying a lifecycle marker and loading facts must be serialized across
  EventWriter replicas, not merely within one process. A check followed by an
  unguarded load is insufficient: retirement racing an in-flight fact load must
  leave no active fact behind. This is an implementation acceptance condition,
  not a claim that the existing warehouse client supplies that guarantee.

This applies equally to ordinary soft deletion, temporary deactivation,
retention cleanup and a merge followed by an authorized unmerge. It grants no
new restore permission and makes no changes to identity resolution or topology.
Address-interval closure and reopening remain in tasks 2.1 and 2.2.

**Alternatives.** Keeping permanent denial would require preventing exposure
from ever returning for a restored identity. Giving each restoration a new
fleet ordinal would violate the current stable-identity contract. A separate
exposure-only ordinal would diverge from the shared device ordinal used by
flows, catalogs and bitmap joins. The lifecycle fence preserves those
joins and prevents stale messages from reviving an earlier incarnation.

**Required evidence before task 1.5 is complete.** Transactional retirement and
rollback; repeated retirement; restore and authorized unmerge retaining the
ordinal; retirement before first fact delivery; pre-retirement facts arriving
after restoration; restored facts arriving before their marker; markers in
reverse order; and retirement racing a fact load in another consumer. Existing
assessment-deletion coverage remains the owner of its new-sequence `resolved`
transition contract. Snapshot reconstruction must retain the lifecycle fence.

Decisions 2, 4 and 14 and the specification deltas incorporate this contract.

**Implementation boundary.** Migration `20261025030000` attaches sequencing and
outbox publication to the fleet-ordinal dictionary itself. Its current writers
are `ensure_device_fleet_ordinal` (including canonical device lifecycle triggers),
`EndpointInventoryMoves` and `DeviceCleanupWorker`. This covers Ash actions and
raw updates of canonical deletion/activation fields without adding parallel
application callbacks. Assessment transactions hold shared ordinal locks before
allocating sequences; a lifecycle change waits for them. Repeated writes keep
the same lifecycle. Restoration queues current assessments transactionally;
the maintenance worker republishes at most 500 rows per page and ten pages per
run, preserving work across retries.

EventWriter serializes each of the existing sixteen transition subject buckets
using a CNPG session advisory lock, held on a direct connection that bypasses
the transaction-mode pooler: through the pooler, the lock and its unlock can run
on different server backends and strand the lock on a shared one. Its durable
control journal records source positions and the delivery operation, never
exposure payloads. A replacement owner fetches and replays an unfinished batch
before admitting another, settling its immutable warehouse load labels. The
journal insert does nothing when that bucket row already exists, and the
delivery is busy without a load; finishing removes the journal only for the
operation this run created or adopted. Decision 25 binds that removal to the
operation, so matching source positions are not enough. Namespace 74523 was
never in a tagged release (it landed after v1.4.97), so a mixed-version
overlap only affects an installation running an untagged staging build during
this upgrade, and draining to one EventWriter for that upgrade is optional.
Every physical load, including a size-split chunk, checks that the owning
session still holds the bucket lock. Retirement uses bounded pages and retains
unfinished work.
Retirement appends each known fact's terminal after-image to transition history
before loading its terminal current state. A retry after a committed fact load
will no longer select that key, so appending first prevents a crash from losing
the history entry. The history payload identifies `device_retired` and carries
its derived terminal after-image; it is not an assessment wire message.
Labels include fact keys and sequences because separate retirement pages share
one retirement sequence. Exposure delivery has unlimited attempts within stream
retention, so waiting for a lifecycle marker cannot become a terminal ACK.
The source relay withholds a lifecycle's facts until its marker receives PubAck;
otherwise future facts could fill the bounded pending window before the marker
is delivered. Independent subject buckets continue even when one is blocked.

A journal position no longer retained by JetStream fails closed. It must be
recovered by the snapshot protocol in task 1.6; deleting the journal manually is
not a safe repair. Snapshot readiness must include unfinished delivery journals,
restoration queues, and reconstruction of lifecycle state for ordinals retired
before this migration. This slice supplies the lifecycle path; it does not mark
snapshot recovery, address interval handling, or exposure readiness complete.

**Validation (2026-10-24).** The full remote Bazel unit sweep and all seven
Elixir format/Credo checks passed on the final implementation. The two
platform-specific Swift targets were skipped. A negative control restored the
old delivery-limit handling and failed with a terminal ACK instead of the
required retry; restoring the fix passed. HTTP boundary coverage verifies stale
and future lifecycle handling, physical-load ownership loss, and retirement's
history-before-fact ordering. Hosted CNPG integration and warehouse storage
checks remain required; no product rollout or end-to-end live validation is
claimed here.


**Hosted validation (2026-10-25).** PR [#5995](https://github.com/carverauto/serviceradar/pull/5995)
merged after all 21 checks passed, including BazelCI Core Integration, BazelCI
Web-NG DB and SrqlParity. The core integration run passed all twelve targets,
including its eight core lanes
([invocation](https://carverauto.buildbuddy.io/invocation/9e928a26-fb67-4566-a470-98e17c4beb1d)).
SrqlParity executed migration 0034 and passed the exposure storage contracts
([invocation](https://carverauto.buildbuddy.io/invocation/3973de20-13d3-468f-8a1c-0516045116d0)).
Task 1.5 is complete at this producer/ingestion boundary. Task 1.6 still owns
snapshot reconstruction and readiness; this is not evidence of a live rollout.

### Decision 24: Retain the source publication needed for snapshot replay

**Approved by the product owner on 2026-10-25.** This decision covers the source-side
prerequisite for task 1.6. It does not approve or complete the snapshot transport,
warehouse finalization, delivery-journal recovery or daily reconciliation.

**Gap this decision closes.** Before migration `20261025185606`, an assessment retained
`last_transition_seq`, `last_device_lifecycle_seq` and `exposed_at`, but not the
publishing transaction's `transition_xid`, publication time, or exact after-image.
`exposure_record_transition` constructed those values only in the outbox, and
`ExposureOutboxRelay` deleted the row after PubAck. Deletion watermarks retained
sequence, xid and time but not the complete terminal after-image. Unrelated assessment
updates could change fields without publishing a transition. Snapshot code could not
reconstruct an identical old publication from the current assessment, its PostgreSQL
row version, or the surviving watermark. Decisions 14 and 19 require the original
transaction fence and forbid changing content under an existing sequence.

**Producer state.** Retain one last published schema-version-1 payload
on each assessment, and one terminal payload on each deletion watermark. These
are source publication records, owned by the same transaction and full fact-key
serialization as sequence allocation and the outbox insert. The retained payload
and the outbox payload must be identical, including sequence, xid, lifecycle and
timestamps. An unrelated assessment update must preserve that payload. Source scope is
actionable fact content: a change on an actionable assessment publishes a fresh
complete after-image under a new sequence and the producing transaction id.
Setting the same scope again, or changing only metadata, preserves the retained
publication. A candidate's scope change publishes nothing. A rollback
must preserve neither a new publication record nor its outbox message.

This state serves publication and recovery only. Exposure queries continue to
read StarRocks; no catalog grant, exposure reader or CNPG fallback may use these
payloads. Store only the latest publication for a key, not an additional event
history. Deletion atomically transfers the new terminal publication to the
watermark; re-creation removes that watermark with its new assessment transition,
as already required by Decision 20.

The cost is additional CNPG storage and write volume for one payload per current
assessment or deleted key. Record the payload-size and write-cost measurements
on synthetic fixtures during implementation. Keeping only an xid and timestamp
would use less space, but would not recover attributes changed since publication
or the deleted assessment's terminal after-image. Keeping every acknowledged
outbox event would grow with transition history instead of fact-key cardinality.

**Replay and repair.** Snapshot replay copies the retained publication with its
original sequence and xid. It does not rebuild that publication from mutable
assessment columns or substitute the snapshot transaction's xid. Reconciliation
still compares current source attributes with warehouse content: retaining an
old publication must not hide source drift. If current source state needs a new
after-image, the source-locked repair records and publishes it under a new
sequence, then a subsequent snapshot can replay it exactly. The existing
Decision 20 absent-key serialization and source recheck remain required.

**Existing rows.** A migration adds nullable publication fields without a fleet
rewrite. Before an authoritative snapshot is admitted, bounded, resumable source
preparation supplies missing publication records through fresh transitions under
the same serialization. It uses current source state, assigns a new sequence
greater than the key's known watermark, and records the actual producing xid.
It must not invent the xid of an old acknowledged message or republish changed
content at its old sequence. An unsequenced legacy assessment therefore receives
its first real publication before snapshot emission; NULL remains equivalent to
zero for comparison during preparation. Stored-terminal repair, including exact
replay below the stored sequence and sparse preparation of a null legacy payload,
follows *Exposure Is Rebuildable And Reconciled Against The Assessment Store*.
Preparation must respect device lifecycle
fences and finish or explicitly report outstanding work, including the existing
restore queue and pre-migration retirement bootstrap. Dictionary preparation and
replay remain part of the Decision 22 rebuild gate.

**Acceptance evidence for the source slice.** Extend the canonical assessment
transition integration suite to cover retained replay after successful PubAck
removes the outbox row; an unrelated update preserving the original xid and
payload; rollback; deletion and re-creation; concurrent repair and creation in
both orders; and bounded restartable preparation of legacy rows. Each source
repair must reach the existing JetStream outbox path. Hosted CNPG integration
is required before readiness. Later snapshot tests must additionally prove that
the retained publications survive delivery reordering and enforce the recorded
`pg_current_snapshot()` fence. Task 1.6 remains unchecked until those consumer,
recovery and reconciliation guarantees also pass.

**Source implementation boundary.** Migration `20261025185606` adds the two
nullable publication fields and replaces the source trigger functions. Fact-key
locks cover insert, update, key change and deletion. Repair runs in a fresh
`READ COMMITTED` transaction and uses a non-waiting assessment row lock after the
fact-key lock, so it retries instead of waiting on a writer with the reverse
row/key lock order. An empty publication assignment is the internal regeneration
request; the trigger replaces it with a complete fresh publication atomically.
Ordinary NULL legacy records and unrelated source writes do not request repair.
All exposure sequence allocators share a short session lock around allocation
and any required sequence advance, released before the transaction completes.
This keeps a high observed sequence from causing an unbounded allocation loop
or racing another allocator.

`ExposurePublicationPrepareWorker` runs an hourly maintenance pass, at most 500
source rows per invocation. Its lifecycle, assessment and watermark cursors are
stored in the Oban job in the same transaction as each page. It snoozes while the
combined transition/dimension outbox backlog reaches 10,000 rows, and records
prepared and deferred counts. A tombstoned assessment remains deferred to its
lifecycle fence; an ordinal retired before lifecycle publication is bootstrapped
first. A pass can finish while a later insert falls behind its cursor, so pass
completion is deliberately not a snapshot readiness signal. The future snapshot
coordinator must verify its own preparation scope, restore queues, delivery
journals, dimensions and warehouse reconciliation. This source slice supplies
no warehouse snapshot transport or finalization and leaves task 1.6 unchecked.

**Pre-publication validation (2026-10-25).** The full remote Bazel unit sweep,
including all Elixir format/Credo checks, passed: 460 test targets passed and
the two platform-specific Swift targets were skipped
([invocation](https://carverauto.buildbuddy.io/invocation/e50948fa-aa95-412e-b111-3b41ecd3182f)).
Strict OpenSpec validation passed. These checks do not execute the new SQL
migration or database scenarios. Hosted CNPG integration, a database negative
control, and synthetic storage/write-cost measurements remain required before
readiness. No live rollout is claimed.

### Decision 25: Complete snapshot generations and retain unfinished delivery inputs

**Approved by the product owner on 2026-10-25.** This settles
the remaining task 1.6 protocol after #6002. Decisions 14, 19, 20, 22, 23 and 24
continue to own source visibility, sequences, lifecycle fencing and repair.

**Concrete gap.** `ExposureDelivery` records only positions in
`EXPOSURE_TRANSITIONS`. A replacement consumer must replay the unfinished batch
before admitting another write, because its predecessor may have left a warehouse
load in flight. If the seven-day stream or its byte limit removes that message,
the journal cannot reconstruct the batch. A new snapshot cannot safely erase
that journal and let an unknown old load finish afterward. Also, the existing
live load label identifies fact keys and sequences, so reusing it for an
otherwise identical snapshot would not perform the new generation-marker write.

**Retain only work that has not finished.** Add one file-backed JetStream stream,
`EXPOSURE_RECOVERY`, for immutable snapshot envelopes and unfinished delivery
copies. It has limits retention, no age expiry, discard-new, a bounded byte
budget, and one message per exact subject with `discard_new_per_subject` enabled.
An envelope subject contains its durable operation identity. Retrying an
uncertain publication reads that subject and verifies identical bytes; it does
not rely on the ordinary duplicate window. A different payload for the same
identity fails closed. NATS documents the required
[per-subject insert semantics](https://nats.io/blog/new-per-subject-discard-policy/)
and [discard-new behavior](https://docs.nats.io/learn/jetstream/shaping-the-stream).

The initial transport bounds are 500 records and 512 KiB per complete encoded
envelope, one unfinished live envelope per existing device bucket, and one
unreceipted snapshot page per lane. Split before admission, never after reserving
an unbounded batch. A single oversized record fails visibly; it is not truncated
or acknowledged as processed. Use 64 MiB for this stream in every installation
profile initially. This is a storage ceiling, not an instruction to preallocate
memory. Publication backpressure must leave room for bounded control messages and
cleanup; it must not evict an unfinished envelope. Validate the minimum-profile
capacity and progress under a full stream before enabling the protocol.

CNPG keeps operation IDs, source positions, envelope hashes and positions,
generation manifests, receipts, cursors and completion state. It keeps no copy of
the recovery envelope's fact payload. These are control records, not a new
exposure projection. Core publishes snapshot subjects; EventWriter publishes and
reads its delivery-copy subjects, consumes snapshots and deletes only completed
envelopes. Permissions do not grant either component a general stream purge.

**Delivery recovery.** Under the existing bucket ownership lock, first create a
durable `capturing` journal identity, then retain the complete original batch in
JetStream. Record its verified recovery position and move to `applying` before
the first warehouse call. The existing ingestion path and immutable load labels
then settle that exact batch on any replacement owner, even when the original
transition messages have expired. No change to Stream Load retry internals is
needed for this contract.

After all loads settle, record `complete` before deleting the recovery envelope;
only then remove the journal and admit the next batch. Phase changes and journal
removal match the operation this run created or adopted. Another operation keeps
its phase, journal and recovery position when the source positions are the same.
The only claim on a journal that has no operation yet is the initial legacy
adoption, and it applies only while that operation id is still null. A crash
between completion and cleanup resumes cleanup without reapplying data. A crash
while capturing cannot have started a warehouse load: if neither the retained
copy nor the original messages can be obtained, abandon that unstarted
operation and request a fresh snapshot. Its missing input is reported, not
counted as delivered.

An old journal created before this protocol must first finish through its old
replay path, or be upgraded by retaining its still-available exact inputs before
another load. If those inputs are already gone, keep the affected bucket blocked.
That case requires a separately scheduled operator recovery which proves old
warehouse writes are quiescent; this proposal does not authorize deleting the
journal, resetting the warehouse, or claiming automatic recovery of lost NATS
storage. A snapshot restores current state, not missing historical transitions;
record a history gap when original transitions are no longer recoverable.

**One snapshot generation at a time.** Allocate a monotonically increasing
generation `G` in a durable coordinator record with either deployment or one
device as its scope. Queue other requests and coalesce repeated requests for the
same device. A source reader uses the one read-only `REPEATABLE READ` transaction
and first-statement `pg_current_snapshot()` required by Decision 14. Keyset-page
the source; do not materialize the deployment in memory. Check preparation,
dictionary publications, lifecycle bootstrap and restore work in that same
snapshot. Missing prerequisites make the generation incomplete and schedule
bounded preparation outside the read transaction.
The reader has a finite configured deadline; timeout or sustained backpressure
aborts the generation rather than pinning CNPG's MVCC horizon indefinitely.

Envelopes carry protocol version, `G`, scope, the recorded snapshot identity,
lane, contiguous page number, record count and content digest. The lanes are the
existing sixteen device buckets plus the two dimension kinds. Lifecycle and
assessment records for a device stay in its bucket. Replay exact retained
assessment, watermark and dimension publications. A retired ordinal is covered
by its lifecycle fence; do not manufacture an active after-image or a replacement
transaction ID for it. Apply the generation's dimensions and lifecycle coverage
before emitting fact pages, using receipted phase boundaries within the same
recorded snapshot.

The start marker establishes the manifest. Each receiver durably advances its
contiguous receipt and rolling digest only after that page's warehouse effects
are confirmed. It then permits cleanup and the next page. Counts and chained
hashes cover the envelope identity and ordered records, so a duplicate receipt
cannot fill a missing page. Keep per-lane progress and bounded pending state,
not one permanent CNPG receipt per fact or every historical page. The end marker
declares each lane's final page, record count and digest; empty lanes are explicit.
Receiving the end marker alone never authorizes finalization.

If the reader loses its transaction or producer ownership before recording a
complete end manifest, mark `G` aborted and restart with a new generation and
snapshot. Never resume a saved cursor under a different database snapshot while
retaining `G`. Already-applied rows remain valid sequenced after-images, but an
aborted generation cannot sweep unseen rows or establish readiness. Settle its
unfinished loads through retained envelopes before admitting a successor's writes;
reject late messages for the aborted generation. Ownership and cleanup are fenced
by the durable generation state, including delayed publication after cancellation.

**Warehouse application and finalization.** Snapshot loads use a separate stable
label namespace including generation, lane, page and physical chunk.
Chunk identity includes its content digest so a different size split cannot reuse
a label for different rows. Snapshot replay rebuilds current state and does not
invent missing transition-log history. Live replay
keeps its existing labels and never writes `snapshot_generation`. Snapshot
comparisons and generation-marker writes use the same cross-replica bucket lock
as live transitions and retirement. Dimensions receive equivalent serialization
between their live and snapshot writers. An equal-sequence content mismatch
requests a source-locked fresh publication; it is never overwritten in place.
A newer warehouse transition not visible in `V` is preserved and accounted for
as post-snapshot work. Retired-lifecycle drops are likewise explicit outcomes,
not missing pages.

Only matching complete receipts for every declared lane admit the end-marker
scan. Scan the scoped warehouse in bounded keyset pages. Apply Decision 14's
`transition_xid` visibility rule to untouched rows, then use the existing
source-locked repair path in fresh transactions. Persist repair requests and
verify the resulting source sequence has reached the warehouse, or has been
superseded by a valid newer transition. Outbox PubAck is not warehouse evidence.
An interrupted finalizer resumes its cursor and outstanding repairs; it cannot
mark the generation complete merely because it dispatched them.

**Reconciliation and readiness.** Run the approved daily per-device comparison
over the union of source and warehouse device ordinals, including warehouse-only
devices. Use bounded reads and one versioned canonical fact encoding for the
specified identity, sequence and actionable attributes on both sides. Compare
the count and an order-independent sum of SHA-256 row hashes modulo 2^256;
include the key and explicit null/type encodings. Reconciliation reads current
source attributes, not only retained publications, and also checks lifecycle and
dimension state. Live changes may cause a retry or a repair request; rechecking
under the source locks preserves those changes.

Export inspected-device, mismatch, deferred, repair-pending, generation-age and
delivery-recovery counts. A completed generation records its fence and verified
coverage. Exposure readiness additionally requires prepared sources, restored
device work and dimension coverage, no unresolved scoped delivery journal, and
no unresolved comparison/repair obligation. Ordinary live traffic continues;
readiness does not require a globally empty outbox. Freshness still uses the
existing age gates. StarRocks-disabled behavior and CNPG assessment queries are
unchanged. Task 1.6 stays open until the entire protocol is validated.

**Delivery order and evidence.** Implement in three reviewable PRs: (1) retained
delivery envelopes and crash-safe cleanup, (2) the bounded source publisher and
snapshot ingestion/finalization, (3) reconciliation and readiness. They form one
approved contract, so routine implementation choices do not need new product
decisions. Each PR uses no-mistakes and hosted checks; no rollout is included.
Acceptance must cover original-stream expiry during an unfinished load, crashes
at capture/apply/receipt/cleanup boundaries, duplicate and conflicting envelopes,
missing/reordered pages and early end markers, aborted-reader restart, generation
label separation, both orders of concurrent live resolution, equal-sequence
drift, lifecycle restoration, missing dimensions, out-of-band warehouse deletion,
warehouse-only devices, full-stream backpressure and a legacy unrecoverable
journal staying blocked. Prove negative cases can fail; report the remaining
fleet-scale performance gate separately from small synthetic correctness tests.


**First implementation slice.** `ExposureRecovery` retains deterministic envelopes
and verifies their hashes through the real JetStream API. The delivery journal
uses `capturing`, `applying`, `complete` and `snapshot_required`; migration
`20261025234000` classifies existing journals as `legacy`. A confirmed missing
unstarted input leaves its source positions in `snapshot_required` for the later
coordinator; it does not clear the bucket or report delivery. Legacy uncertainty
remains blocked. This slice includes no snapshot producer, finalizer,
reconciliation or readiness signal, so task 1.6 remains unchecked.

The chart and single-server capacity checks include the fixed recovery
reservation. The smallest chart profile reserves about 1.44 GiB against its
1.58 GiB planning limit. Real-broker tests exercise immutable repeat publication,
conflicting content, the full 64 MiB stream, deletion retries and forward progress
after cleanup. Database tests own interrupted delivery and cleanup behavior.
Before an eventual rollout, quiesce old-version exposure consumers: their old
journal cleanup cannot account for retained envelopes. No rollout is included.

**Second implementation slice.** Migration `20261026061000` adds snapshot
generation control and bounded source-repair helpers. The source worker holds
one direct read-only transaction, publishes at most one pending page per lane,
and waits for dimension and lifecycle receipts before facts. Loss of its reader
aborts the generation; maintenance schedules a fresh generation instead of
reusing its cursor.

EventWriter retains an immutable warehouse plan before applying a page. The plan
also retains load-size limits, so a replacement consumer settles the same
physical chunks even if runtime batching changes. Device and dictionary writers
share lane ownership. Equal-sequence drift produces a fresh source publication;
the stored repair obligation includes the required sequence and content digest.
An outbox acknowledgement cannot discharge it. Only confirmed warehouse content
or a valid newer source publication permits the page receipt.

The finalizer scans in bounded keyset pages, persists its cursor together with
repair obligations, and validates retirement coverage against both retained
source and warehouse fences. This slice adds no scheduled fleet reconciliation,
readiness signal, or rollout. Task 1.6 remains open; fleet-scale throughput and
the complete readiness contract require separate evidence.

**Completion during live traffic.** On 2026-10-26 the product owner confirmed
that a verified generation may reach `complete` while ordinary live delivery
continues. The end marker records the operation ids of in-scope `applying`
journals when the generation enters `finalizing`. That list is the retained-load
fence, at most one operation per bucket. Completion waits while any fenced
operation is still `applying`, while a repair obligation is unverified, while
a retained snapshot effect is unsettled, or while a legacy journal remains in
scope. A `capturing`, `applying`, or `complete` journal that appears after the
fence is ordinary traffic and stays out of it. A deployment generation's fence
and legacy check cover every bucket. A device generation covers that device's
bucket. A missing ordinal leaves both checks empty.

A `snapshot_required` row that is still present after the fence is clear is a
confirmed missing input discovered after the end manifest. The finalizing
generation aborts with `exposure_snapshot_required`, keeps the `history_gaps`
it already recorded, and leaves the journal row in place. Finalization then
queues one fresh full snapshot. The successor's start accounts for those rows
once, on that successor. A repeated start, after the rows are gone, adds
nothing. `history_gaps` belongs to the generation that records it. The
successor's count is the gaps it discovered on its own start, and the aborted
generation keeps the count it had. Legacy uncertainty keeps the generation
finalizing, because a fresh snapshot cannot retire a pre-protocol journal.
This `complete` status is not slice 3 readiness. Outbox PubAck still cannot
discharge a page.

A disposable scratch StarRocks schema confirmed the in-flight storage example
on 2026-10-26: a snapshot write of active sequence 40 followed by live sequence
41 ends resolved at 41 and keeps the snapshot marker; live sequence 41 followed
by the older snapshot write also ends resolved at 41; a later live sequence 42
wins and keeps the marker. Filtered rows stayed zero. The schema was dropped
afterward. That probe is storage evidence. Hosted invocation cf414b06 on tree
81ae24f4 ran 459 tests with one failure, a duplicate journal primary key;
observer, teardown and release exited 0. Hosted owner 50af35c1 on commit
95336bd, tree 66a1a3e06e3d91cc71103df577ced69e11a41879, passed 460 tests under
parent d1b0aae8. That run exercised the previous completion gate. Remote unit
invocation 0523e10b passed 460 targets, failed the core format check, and
skipped 2 preexisting targets; web-ng `phoenix_other` passed on an automatic
retry. The fresh-repair negative control on tree
3085874ff12e45a7089e42e332f712cf774d55f3, owner bd602729, produced the two
intended fresh-sequence failures. The hosted run of this final tree is still
required before task 1.6 can close.

## Section 0 evidence (2026-10-21)

### Task 0.6: synthetic warehouse spike

The product owner authorized an isolated, disposable database on the existing lab
warehouse for this run. No deployed telemetry or inventory rows were used as fixtures.
The separate CNPG fixture database supplied a synthetic 20,000-row catalog view over
JDBC with TLS certificate and hostname verification. The warehouse profile was
StarRocks 4.1.3, shared data, three compute nodes, each requesting 2 CPUs and 8 GiB of
memory with a 10 GiB memory limit. This was a shared warehouse, not a quiet benchmark
cluster or a final capacity certification.

The fact table used the Decision 2 columns, primary key, sort key and 16 buckets.
Server-generated integers produced exactly 50 million facts, 20,000 hosts, 50,000 CVEs
and 500 package identities. Each host had 2,500 facts and each CVE had 1,000 exposed
hosts. Names and versions were invented. Bulk seeding used one-million-row SQL batches;
conditional updates were tested separately through actual Stream Load on the 50-million
row table, with strict mode and zero filtered-row tolerance.

| Check | Rounded result | Gate |
|---|---|---|
| Newer complete after-image followed by an older transition | Newer resolved state, KEV and CVSS retained | Pass |
| Identical duplicate under a new Stream Load label | Same fact state and sequence retained | Pass |
| Resolution reflected in CVE bitmap | Synthetic CVE fell from 1,000 to 999 members after refresh | Pass |
| CVE bitmap full refresh with BIGINT | About 6 s | <= 60 s: pass in completed run |
| Severity/KEV bitmap full refresh with BIGINT | About 4 s | <= 60 s: pass in completed run |
| Device summary full refresh with BIGINT | About 2 s | <= 60 s: pass in completed run |
| Use case 1 rows with BIGINT, including synthetic JDBC device view and package/CVE joins | Warm p95 about 150 ms; maximum about 350 ms | <= 500 ms: pass |
| Use case 1 bitmap counts by site with BIGINT | Warm p95 about 130 ms; maximum about 160 ms | <= 1 s: pass |
| Equal sequence with conflicting after-image | Overwrote the resolved state with active | Expected negative control; Decision 19 approved |
| Upper-half u32 device ordinal in proposed `INT` column | Stream Load rejected the row | Expected negative control; BIGINT retest passed |

Each latency series discarded two warmups and measured 20 requests across 20 CVEs.
The row query returned 200 rows each time, ordered by hostname, device id and package;
counts returned the five populated synthetic sites for each CVE. Timings came from
the MySQL client running beside the frontend, at 10 ms resolution, and include the
warehouse/JDBC execution and result transfer but exclude SRQL, web and workstation
transport overhead. Automatic materialized-view rewrite was disabled to keep the
measured row and bitmap-count paths explicit. The views were refreshed manually with
the async-MV engine, including forced full refreshes; scheduling jitter was not measured.
The rounded BIGINT refresh durations include command transport overhead. The original
signed-INT run also passed these latency gates; the table reports the widened-key
measurement. Sequence correctness was exercised on the original 50-million-row table
and on a separate BIGINT boundary fixture; the widened scale table independently
matched all 50,000 CVE counts against facts.

One separate repeat failed during a risk-view refresh with a storage-shard RPC
deadline exceeded. That repeat is excluded from the successful durations, as are two
attempts stopped by measurement-query errors that were corrected before the final run.
These results establish Section 0 query-shape feasibility on the shared warehouse;
they do not certify production refresh reliability or replace the sustained-load and
freshness validation in Section 8.

An independent fact-to-view comparison found zero CVE-membership/count mismatches and
zero device-summary mismatches with rewrite disabled. The first comparison using
`COUNT(DISTINCT device_ord)` exceeded a compute node's process memory limit. Repeating
the comparison with `bitmap_union_count(to_bitmap(device_ord))`, two-way pipeline
parallelism and a 2 GiB query limit succeeded. The failed comparison is not counted as
a passing check or a query-latency measurement. It supports keeping bitmap counting in
the verification path as well as the product query path.

The scale database, synthetic CNPG database and temporary JDBC catalog were dropped;
subsequent catalog/database checks confirmed removal.

### Task 0.2: read-only cleanup follow-up

The initial read-only check found active orphan-match and actionable-assessment
counts that both rounded to zero (nearest hundred), but did not establish a
subsequent matcher completion. That initial observation alone did not pass the gate.

A follow-up on 2026-10-22 found a successful matcher completion in a bounded scan
of current core logs, after the earlier check. A subsequent CNPG read-only
transaction verified that no active match referenced a package that was no longer
current on its device. The actionable-assessment count still rounded to zero
(nearest hundred). Retained Oban history did not contain a completed matcher job;
the positive completion log and the database recheck after it supply the evidence.
No cleanup or scheduling writes were made during verification. Task 0.2 is complete.

### Task 0.5: read-only measurement availability

Warehouse metadata was rechecked on 2026-10-22. It does not yet have
`host_connection_summaries`, the address-validity dimension, or any of the six
per-side device ordinal, resolution and attribution-outcome columns required by
this change. The existing `ocsf_network_activity` table was the positive control
for the metadata query.
It still has the legacy process-attribution observations. Therefore the host evidence
key and host pre-aggregation measurements cannot be made against the specified input,
and the actual mapped-side network write ratio cannot yet be established.

A diagnostic over one fully closed, older UTC hour observed approximately 17,000 flow
rows from an anonymous exporter and approximately 2,000 distinct endpoint-perspective
keys across both sides (about 13% of flow rows). Its key included local and peer IP,
direction, protocol, service port, process, workload, partition and exporter. These
are hourly raw-endpoint keys, without the not-yet-available device/package mapping.
This is **not** the per-batch pre-aggregation ratio and does not satisfy the 25% gate.
No hostname, address, exporter identity or deployment name is retained here. Task 0.5
remains open; the async-network-view fallback is not selected from this proxy.

### Task 0.7: existing implementation and headroom

Commit `00b50937570cd66ae021c2a9ad7065590facaab5` already changed
`EndpointInventoryFleetOrdinal` to delegate to the shared `FleetIdentity` dictionary.
The canonical device insert/lifecycle triggers cover raw SQL writers as well as Ash,
exclude service-component ids, and provide bounded backfill for existing devices.
The migrations `20261016035900_widen_fleet_ordinals` and
`20261016040000_generalize_fleet_identity_dictionaries` already enforce a non-cycling
u32 sequence and a bigint column with a u32 check constraint.

A read-only lab transaction found no live, non-service device missing a non-tombstoned
ordinal. The maximum allocated ordinal, rounded up, was below 0.4 million; more than
99.99% of the u32 range remained. This confirms present headroom, not the future address
publisher's coverage. The existing integration tests exercise canonical and raw inserts,
service exclusion, stable allocation, lifecycle changes and ordinals above the signed
32-bit boundary. A fresh synthetic CNPG scratch database also executed the SQL from both production
migrations. Before applying them, a canonical insert allocated no ordinal (the negative
control). Afterwards, assertions passed for raw non-service insert allocation, service
exclusion, stable lookup without sequence consumption, delete/restore tombstoning with
identity retention, an ordinal above the signed 32-bit boundary, rejection above the
u32 maximum, and a non-cycling sequence. The transaction-owned test rows rolled back;
the scratch database was removed after the warehouse benchmark. This verifies the
allocation needed by the future address publisher without changing the shared identity
implementation. The existing Elixir integration module was not re-run locally.

## Capacity model

| Quantity | Target | Basis |
|---|---|---|
| Devices with ordinals | 20k agent-managed hosts and up to 1M inventory devices | u32 ordinal range; roaring compresses dense small integers |
| Active facts | 50M (about 2,500 per host) | upper bound for package-heavy servers |
| CVEs with at least one exposure | 50k | about 250k in the catalog |
| Bitmap views | under 200 MB | at most 50k bitmaps over ordinals below 2^20 |
| Transitions | sustain 5k/s; drain a 1M-transition burst in <= 10 min | an advisory promotion or KEV listing touching a ubiquitous package |
| Host summaries | as sized by #5753: at most 2,000 rows per agent per minute (about 33 rows/s), an estimated 67k-200k rows/s fleet | *Hosts Report Per-Process Connection Summaries As Evidence*; this change adds no cap |
| Host-derived evidence writes | per host, <= 25% of its summary rows after pre-aggregation, so at most 500 rows per minute; fleet about 17k-50k rows/s against 67k-200k summary rows/s | bounded by the #5753 summary cap; gated by measurement in Phase 0 |
| Network-derived evidence writes | per exporter, <= 25% of its flow rows after pre-aggregation | at most two sides per flow before aggregation; gated by measurement in Phase 0 |
| Fact watermarks | one row per fact key ever seen, about 24 bytes before compression | kept permanently; payloads compacted after 7 days resolved |
| Discrepancy candidates | <= 100/s fleet in steady state | a `no_owner` on an attested address is rare when healthy |
| Catalog device views | <= 250k rows; above that, mirror into StarRocks | JDBC pulls the whole view |

Latency budgets (p95, warm, at the targets above, on the reference warehouse profile in the
runbook):

| Query | Budget |
|---|---|
| Use case 1, rows | 500 ms |
| Use case 1, `count_distinct` by site | 1 s |
| Use case 2, 24 h | 3 s |
| Use case 3, 24 h | 5 s |
| Use case 4, 100 seeds, depth 2 | 3 s |
| Use case 5 | 2 s |
| Use case 6, 90 days | 2 s |
| Discrepancy listing | 1 s |
| Each pivot | 2 s |

Refresh budgets:

- each view refresh completes in <= 60 s at 50M facts;
- the daily snapshot job completes in <= 5 min;
- the hourly `host_only` evaluation completes in <= 5 min;
- the tombstone compaction and the daily reconciliation each complete in <= 15 min.

## Risks / Trade-offs

- **Exposure is only as right as the assessments.** A pre-fix #5749 measurement found
  about 97% of "active" rows on a lab deployment were orphans. The 2026-10-22
  read-only follow-up, after a successful matcher completion, found no active orphan
  matches, and the actionable count rounded to zero (nearest hundred). Phase 0 still
  gates on a reconciliation that can fail.
- **Evidence write amplification.** Network evidence is written per flow side and host
  evidence per summary row, each budgeted against its own source. Mitigation:
  pre-aggregation per batch, Phase 0 measurement gates, and an async view over flows as the
  fallback design for network evidence.
- **Strict sampling rule.** sFlow-only deployments get no `network_only` signals.
  Mitigation: suppressed candidates are recorded and counted, so the gap is visible; a
  multi-vantage extension is an open question.
- **Catalog availability.** If the JDBC catalog is down, rows lose their names. SRQL then
  returns an explicit `catalog_unavailable` field state, never empty names presented as
  data.
- **Clock and NAT complexity.** Every uncertain case suppresses with a reason. Suppression
  counts are exposed per reason, so a detector that suppresses everything is visibly
  broken, not quietly green.
- **Two-phase blast radius.** Cross-store latency adds up. Mitigation: seed and node caps,
  and truncation flags.

## Migration Plan

1. Phase 0 prerequisites and gates (`tasks.md`); finish the remaining attribution
   and measurement gates before traffic evidence integration and launch.
2. Independently build dictionaries, fact table, transitions processor and snapshot
   (Decision 21). Seed by snapshot and verify with reconciliation before any SRQL
   entity is exposed.
3. Address dimension and flow stamping (a straight switch; history is not backfilled).
4. Evidence, views, snapshots, and the SRQL entities.
5. Coverage attestation, discrepancy evaluation, alerting.
6. Rollback:
   - the exposure tables and views are derived and can be dropped;
   - removing the processors stops writes;
   - the flow columns stay (nullable);
   - CNPG assessments are untouched throughout.

## Known edge cases and deferred decisions

| Case | Intended handling |
|---|---|
| A transition for a retired ordinal arrives after the retirement | An older lifecycle is dropped and counted. A future lifecycle stays retryable until its marker. An authorized restore republishes current facts on the same ordinal (Decision 23). |
| A deleted assessment key is re-created later | Under the shared full fact-key serialization, the re-creating transaction draws a new sequence above the terminal watermark's and removes the key's row from `platform.exposure_fact_watermarks` in the same transaction. |
| An active warehouse fact has neither an assessment nor a source watermark | Snapshot repair rechecks under the same fact-key serialization as creation, then records a new terminal watermark and outbox transition atomically if the source is still absent (Decision 20). |
| A transitions-stream message expires (`max_age`) before it is consumed | Freshness is lost and the stream-age health alert fires; the daily reconciliation finds the device mismatched and a per-device snapshot repairs it. Watermarks still prevent any older state from winning. |
| A warehouse is restored from a backup taken after compaction | Compacted tombstones in the backup still carry their watermark; the snapshot supplies every newer watermark. |
| A `network_only` candidate's tolerance range crosses an hour boundary | It is evaluated with the later hour, the hour containing `flow_end + tolerance`. |
| A flow arrives later than the maximum accepted flow delay | Its sides are `outside_history` and counted; the exporter's hour counts as unhealthy, so it cannot produce a `host_only` gap. |
| An address update arrives after a flow's late-window cutoff | The flow keeps its stamp and `address_update_after_cutoff` is counted. |
| A snapshot row and the stored row share a sequence but differ in state | Counted as a reconciliation mismatch; source-locked repair publishes a new sequence with the current source after-image. |
| A lost transition changes only an attribute (KEV false to true) and keeps membership | The reconciliation digest covers each fact's sequence and attribute content hash, so the device mismatches and a per-device snapshot repairs it. |
| A rule's expected exporter misses a contact that another exporter reports | Network evidence is keyed by `exporter_ord`; the coverage-gap check counts only the rule's exporters, so the gap is still raised for the expected exporter. |
| Watermark growth | Kept permanently (about 24 bytes per key ever seen). Deferred: revisit a retirement-scoped expiry if the key count exceeds the capacity model by an order of magnitude. |

## Implementation record: matcher transitions and incremental matching (#5748, task 0.1)

**Producer.** Migration `20261025185606` (Decision 24) replaces the original trigger
functions, retains the latest publication on the assessment and the terminal publication
on the watermark, and provides `exposure_repair_publication`. Triggers on
`platform.endpoint_vulnerability_assessments` own the outbox, so
every writer (matcher upsert, absence resolution, unconfirmed marking, Ash actions, row
deletion) is covered in the transaction that changes the row:

- a `BEFORE INSERT OR UPDATE` row trigger decides whether the write is a transition (the
  actionable predicate is entered or left, or an actionable row's installed version, KEV,
  exploit, CVSS, severity, fixed version or source scope changed) and, if so, draws `transition_seq` from
  `platform.exposure_transition_seq` while the row is locked and stores it in the
  trigger-owned column `last_transition_seq` (with `exposed_at`, the start of the current
  actionable episode);
- `AFTER` row triggers, which fire only for rows actually written, insert one
  `platform.exposure_transition_outbox` row: the complete after-image as JSON
  (`schema_version` 1), `transition_xid = pg_current_xact_id()`, the changed fields, the
  reason (`entered_actionable`, `left_actionable`, `actionable_attributes_changed`,
  `assessment_deleted`, `assessment_key_changed`) and the device, CVE, package and
  package-version ordinals, allocated in that transaction;
- deleting a row that was ever published (or is actionable) draws a new sequence, publishes
  `resolved` and records `platform.exposure_fact_watermarks`; re-creating the key as
  actionable deletes the watermark in the same transaction.

Rows that were actionable before the outbox existed carry `last_transition_seq` NULL until
their next transition. The snapshot (task 1.6) treats NULL as sequence 0, so any real
transition supersedes it. `device_ord` is read from `platform.device_fleet_ordinals`
without locking the device row; a device with no ordinal is published with `device_ord`
null for the ingestion boundary to count and drop.

**Transport.** `ExposureTransitionRelay` (a coordinator child) publishes outbox rows oldest
first to `vulnerability.assessment.transitions.<bucket>`, where the bucket (0-15) hashes the
device uid, with `Nats-Msg-Id = exposure-transition-<transition_seq>`, and deletes a row
only after its PubAck. The relay creates the `EXPOSURE_TRANSITIONS` stream (limits, file,
R1, `max_age` 7 days, 2-minute duplicate window, `max_bytes` from the JetStream sizing
profile: 1 GiB small, 2 GiB medium, 8 GiB large, 32 MiB tenant-2g) when it starts and
whenever a publish fails, and reconciles an existing stream's `max_bytes` to the profile
size. It publishes `exposure_transition_outbox_oldest_age_seconds`,
`exposure_transition_outbox_pending` and `exposure_transitions_relayed` on
`metrics.exposure_transitions`, and records a health state change for
`exposure_transition_outbox` when the oldest row crosses 10 minutes. The EventWriter
consumer (task 1.4) attaches to this producer-owned stream; it must not create it.

This delivers the producer-side parts of tasks 1.1 (the `transition_seq` sequence,
`transition_xid` on outbox rows, `exposure_fact_watermarks`, the advisory, package and
package-version dictionaries and the CVE ordinal function) and 1.3 (the transitions subject,
its stream limits and the core publish permission). Device retirement (`retired_seq`,
task 1.5) landed in #5995. Source publication retention is Decision 24. The snapshot
(1.6) and the address dimension remain open. CVE and package
dimension publication is Decision 22.

**Incremental matching.** The hourly full recompute is replaced by a run every 5 minutes
that evaluates only devices whose inputs changed:

- triggers queue a device when any writer changes its current package rows, or advances its
  current complete scan while one of its active assessments is unconfirmed;
- triggers record an advisory when its content, coordinates or package assertions change;
  the run maps changed advisories to devices through the matcher's own candidate-discovery
  keys (PURL, vendor/product name, CPE vendor/product or `cpe_any`, Ubuntu product lookup
  key, explicit source-package scope), stored per fleet-deduplicated endpoint package, plus
  devices that already hold a match or assessment for an affected CVE;
- promoting a feed generation re-evaluates the advisories whose assertions it made current,
  because the loader rewrites changed advisories in place and promotion changes no row;
- a full pass still runs on first start, every 24 hours, when the feed state (enabled set,
  success and generation presence, assertion freshness) changes, or when more than 5,000
  advisories changed at once.

An inventory or advisory change therefore reaches the assessment, and its transition, within
one run interval plus the run time. Evaluating each distinct package version once across
the fleet (#5748 item 4) is not part of this change.

**Measurements** (scratch CNPG database; synthetic fleets of 13 and 1,000 hosts with 1,000
current packages each; server-side execution times, rounded):

| Quantity | 13 hosts | 1,000 hosts |
|---|---|---|
| Devices evaluated per idle hour | 0 (was 13, hourly) | 0 (was 1,000, hourly) |
| DB time of one idle run (5 small reads and the finding drain) | under 1 ms | under 1 ms |
| Finding-drain read with nothing pending | under 1 ms (was about 1 ms) | under 1 ms (was about 130 ms, a full scan) |
| Full pass: reading every current package | about 10 ms | about 0.2-0.3 s |
| Full pass: unchanged assessment upsert, with / without the sequence trigger | about 25 / 15 ms | about 1.9 / 1.3 s (about 4 us per row) |
| Transition write (outbox row and ordinals) | about 0.1 ms each | about 0.09 ms each (10k KEV flips: 0.55 s to 1.4 s) |
| Change capture on a promoted 1,000-package scan | about 25 ms added | about 20-40 ms added |
| 100 changed advisory keys to affected devices | about 2 ms | about 15 ms |

Full passes drop from 24 a day to 1. The lab measurement in #5745 (about 50 s wall clock
per 13-host pass, most of it outside the database) now applies once a day and, between full
passes, only to the devices a change reaches. Elixir wall time was not re-measured here;
the integration suite asserts which devices each run evaluates.

## Implementation record: assessment transition ingestion (tasks 1.3 and 1.4, partial)

EventWriter attaches an `EXPOSURE_TRANSITIONS` consumer only when StarRocks is
configured. The assessment relay retains stream ownership: the consumer sets
`ensure_stream: false` and does not change the producer's limits or retention.
Helm permits core's EventWriter identity to subscribe to the transition subjects.

`ExposureTransitions` accepts the producer's schema-v1 complete after-images,
validates source u32 device ordinals and positive BIGINT identities, and maps
active/resolved states into the migration 0032 tables. The known severity words
`none` and `unknown` rank 0, then `low` 1, `medium` 2, `high` 3 and `critical`
4. A null severity and every other binary severity, including feed words
such as `negligible` and `informational`, store a null `severity_rank`; the
history payload keeps the original severity string. A missing device ordinal is
dropped and counted. A missing severity key, a non-binary severity, and other
malformed or unsupported messages fail the batch. EventWriter allocates no
identities and has no CNPG exposure write path.

Within one batch the newest complete after-image wins for each fact key; between
loads StarRocks enforces `merge_condition = transition_seq`. Live partial loads
name every event-owned column and omit `snapshot_generation`. Load labels derive
from the target table and the chunk's transition sequences, so identical replay
is stable while a new transition cannot collide with a prior load. The batch
succeeds only after both the fact update and the complete history append succeed;
a failed or filtered load fails acknowledgement. History uses at-least-once
append semantics: regrouping deliveries can append the same transition again,
so future history readers must identify transitions by `transition_seq`.

This delivers the transition-consumer half of 1.3/1.4. Retirement,
snapshot/reconciliation and the remaining lifecycle scenarios are still open.
CVE and package dimension ingestion is Decision 22. No exposure query entity
is enabled by this slice.

## Open Questions

1. Resolved: the product owner approved the StarRocks-required exception for exposure
   intelligence and its host evidence (Decision 15; task 0.9).
2. EPSS availability. If neither feed payload carries EPSS (`add-cve-priority-context`,
   open question), `epss_score` is null and the `epss_score` filter returns an explicit
   `epss_unavailable` state. A dedicated EPSS feed would be a follow-on.
3. Should trend slicing use membership as of each day? That means per-slice snapshots, at
   a storage cost. The alternative is the current-membership behaviour in Decision 11.
4. Should sampled evidence from two or more independent vantage points be allowed to raise
   `network_only`?
5. Where do exporter position (inside or outside NAT) and expected-coverage rules live:
   derived from prefix tags, or in an explicit settings surface?
6. BGP blast radius needs current RIB state. Do retained BMP events suffice, or is a RIB
   snapshot store required?
7. Should `in:exposure` offer an explicit `include_candidates:true`?
8. Is 250k rows the right threshold for mirroring the device dimension into StarRocks?
