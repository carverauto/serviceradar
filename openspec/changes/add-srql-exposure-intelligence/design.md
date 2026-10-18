# Design: Exposure intelligence in SRQL

## Context

What exists today:

| Fact | Store | Identity | SRQL today |
|---|---|---|---|
| Device x package x CVE applicability decision | CNPG `platform.endpoint_vulnerability_assessments` | `(device_uid, package_identity_key, cve_id)`; version-independent package identity | `in:endpoint_vulnerability_assessments`, `in:devices cve:` / `kev:` (EXISTS) |
| KEV, exploit, CVSS on the assessment; EPSS when the payload carries it | same row (`kev`, `exploit_available`, `cvss_score`, `metadata.epss_score`) | as above | as above |
| Device fleet ordinal (`uid -> integer`) | CNPG `platform.device_fleet_ordinals`, allocated lazily for endpoint-inventory devices, tombstoned on merge | `ordinal` from a sequence | none |
| Network flows | StarRocks `serviceradar.ocsf_network_activity` (the only flow store) | flow id; `device_uid` is the **exporter**, not an endpoint | `in:flows` |
| Process attribution on flows | same table (`pid`, `comm`, `container_id`, `workload_identity`) | flow id | `in:attributed_flows` |
| Socket ownership and host peer evidence | leases, an in-memory ownership index and per-process connection summaries (`host_connection_summaries`), as specified by the merged change `stream-flow-attribution-via-ownership-index` (#5753); being implemented | `(partition, proto, ip, port)`; summaries per `(agent, owner, local endpoint, peer endpoint, proto, direction)` | none |
| IOC matches | CNPG `platform.ip_threat_intel_cache`, populated from IPs seen in flows | ip | `in:threat_intel_matches`, `threat_*` filters on flows (StarRocks reads the matched set through `cnpg_platform.native_query`) |
| Topology | graph (AGE / Dgraph) | device uid | `in:device_graph`, `in:graph_cypher` |
| BGP | StarRocks BMP events | peer, prefix | `in:bmp_events` |
| Small current-state dimensions | CNPG, reachable from StarRocks through the opt-in `cnpg_platform` JDBC catalog, with column-scoped grants to `serviceradar_starrocks_reader` and an allowlist in `CatalogAllowlist` | | used by flow enrichment joins |

The gaps that block the six operator questions are:

- nothing maps a flow endpoint or a host peer to a device;
- nothing maps a process to the package that owns its executable (#5752);
- matching is a full hourly recompute that cannot emit deltas (#5748);
- about 97% of "active" match rows on a lab deployment are orphans (#5749), so any count built on them would be wrong;
- host connection summaries (#5753) are stored, but nothing joins them to devices, exposure or flows, and nothing records whether an agent's capture was complete for an interval;
- there is no current-state exposure store next to flows.

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
  device_ord          INT       NOT NULL,
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
  snapshot_generation BIGINT    NOT NULL
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
    `snapshot_generation`, never only the changed fields. It is applied only when its
    `transition_seq` is greater than the stored one, so out-of-order delivery converges to
    the latest complete state and an older or duplicate transition never overwrites it.
  - A resolution is written as `state = 0` and the row stays as a tombstone carrying its
    `transition_seq`.
  - **The row is the fact's sequence watermark, and it is kept permanently.** A daily
    compaction clears only the payload columns of tombstones resolved more than 7 days ago,
    leaving the key, `state = 0`, `transition_seq` and `transition_xid`. Correctness
    therefore does not depend on any delivery horizon: an older active transition delivered
    at any later time still loses to the watermark. Watermark rows cost about 24 bytes each
    before compression, and their number is bounded by the fact keys ever seen, because the
    package identity is version-independent.
  - Delivery delay is bounded for freshness, not for correctness: the oldest unrelayed
    outbox row must be younger than 10 minutes, and the transitions stream keeps messages
    for at most 7 days (`max_age`). Exceeding either raises a health alert. Relayed outbox
    rows are deleted once acknowledged.
- **`transition_seq`** comes from one CNPG sequence. The matcher draws it in the same
  transaction as the assessment change, while holding that assessment row's lock, and
  stores it on the assessment row as its last transition sequence. Two transactions that
  change the same row are serialized by the lock, so per row the sequence follows commit
  order. Across rows it does not, which is why the snapshot fence (Decision 14) uses the
  database snapshot rather than a sequence threshold.
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
  - Allocation widens from endpoint-inventory devices to every non-service device the
    address publisher emits, so agentless devices can carry network evidence and act as
    blast-radius members.
  - When a merge or deletion tombstones an ordinal, the publisher emits a `device_retired`
    transition with a new `transition_seq` `R`, drawn in the transaction that tombstones the
    ordinal and recorded on the ordinal row (`retired_seq`); it is greater than every
    sequence the ordinal's facts carry. No later transition is produced for that ordinal.
    EventWriter sets every fact of the ordinal to `state = 2` (retired) at `R`, closes its
    address intervals, and records the ordinal in the permanent
    `serviceradar.exposure_retired_ordinals`. The shared transition-ingestion boundary drops
    and counts any transition for a retired ordinal, so a fact whose first transition is
    delivered after the retirement never appears. The survivor's assessments then re-emit under the survivor's ordinal.
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
  device_ord INT NOT NULL, hour DATETIME NOT NULL, `partition` VARCHAR(128) NOT NULL,
  direction TINYINT NOT NULL,      -- 1 inbound (accepted), 2 outbound (connected)
  proto TINYINT NOT NULL, service_port INT NOT NULL,
  peer_ip VARCHAR(64) NOT NULL, peer_scope TINYINT NOT NULL,  -- internal, internet, unknown
  pkg_ord BIGINT NOT NULL,         -- 0 when unknown
  process_name VARCHAR(64) NOT NULL,  -- '' when unknown
  workload_key VARCHAR(256) NOT NULL, -- '' when none
  host_connections BIGINT SUM, host_bytes BIGINT SUM, host_packets BIGINT SUM,
  network_flows BIGINT SUM, network_bytes BIGINT SUM, network_unsampled_flows BIGINT SUM,
  first_seen DATETIME MIN, last_seen DATETIME MAX
)
AGGREGATE KEY (device_ord, hour, `partition`, direction, proto, service_port, peer_ip,
               peer_scope, pkg_ord, process_name, workload_key)
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
#5752 resolves an executable to its owning package once per executable inode, and attaches
the inventory package reference to:

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
rows with `peer_scope = internet`, `host_connections > 0` and `network_flows = 0` for
devices covered by a rule.

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
    a `SNAPSHOT` watermark (key, terminal state, sequence) for every other fact key known
    to CNPG in `V`: non-actionable assessment rows carry their last sequence, and
    `platform.exposure_fact_watermarks` covers deleted ones. That table holds the key, the
    `resolved` state and the **new** sequence that the deleting transaction drew and
    published. It also emits `RETIRED(device_ord, retired_seq)` for every tombstoned
    ordinal. It then emits `SNAPSHOT_END(G, V)`.
  - A snapshot row is compared with the stored row on `(transition_seq, state)`. A greater
    sequence is applied. An equal sequence with an equal state changes only
    `snapshot_generation`. An equal sequence with a different state cannot be produced by
    one transition, so it is counted as a reconciliation mismatch and the snapshot's state
    is applied.
  - Example (deletion): an active fact at sequence 10 has its assessment row deleted; the
    deleting transaction draws sequence 11 and records `resolved` at 11. A warehouse still
    holding the fact active at 10 receives the watermark at 11, which is greater, so the
    fact ends resolved.
  - The outbox keeps relaying live transitions throughout. A transition whose
    `transition_xid` is not visible in `V` (in flight or committed after `V` was taken) is
    applied normally whenever it arrives. Its per-row sequence is above the one the
    snapshot read, because it was drawn under the row lock after the visible change
    committed, so the merge condition lets it win in either arrival order.
  - On `SNAPSHOT_END`, rows with `snapshot_generation < G` whose `transition_xid` is
    visible in `V` (`xid < xmin`, or `xid < xmax` and not in `xip`) are resolved, keeping
    their `transition_seq`. Rows last written by a transition not visible in `V` are left
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
- **Per-device reconciliation.** A daily job compares the actionable count and an
  order-independent digest of `(cve_ord, pkg_ord)` per device between CNPG and StarRocks.
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

This needs explicit approval, and the `AGENTS.md` text changes only after it (open
question 1).

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

- **Exposure is only as right as the assessments.** With #5749 unfixed, about 97% of
  "active" rows on a lab deployment are orphans. Phase 0 gates on #5749 and on a
  reconciliation that can fail.
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

1. Phase 0 prerequisites and gates (`tasks.md`).
2. Dictionaries, fact table, transitions processor, snapshot. Seed by snapshot and verify
   with reconciliation before any SRQL entity is exposed.
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
| A transition for a retired ordinal arrives after the retirement | Dropped at the ingestion boundary and counted; the ordinal's facts stay retired. |
| A deleted assessment key is re-created later | The re-creating transaction draws a new sequence above the deletion's and removes the key's row from `platform.exposure_fact_watermarks` in the same transaction. |
| A transitions-stream message expires (`max_age`) before it is consumed | Freshness is lost and the stream-age health alert fires; the daily reconciliation finds the device mismatched and a per-device snapshot repairs it. Watermarks still prevent any older state from winning. |
| A warehouse is restored from a backup taken after compaction | Compacted tombstones in the backup still carry their watermark; the snapshot supplies every newer watermark. |
| A `network_only` candidate's tolerance range crosses an hour boundary | It is evaluated with the later hour, the hour containing `flow_end + tolerance`. |
| A flow arrives later than the maximum accepted flow delay | Its sides are `outside_history` and counted; the exporter's hour counts as unhealthy, so it cannot produce a `host_only` gap. |
| An address update arrives after a flow's late-window cutoff | The flow keeps its stamp and `address_update_after_cutoff` is counted. |
| A snapshot row and the stored row share a sequence but differ in state | Counted as a reconciliation mismatch; the snapshot's state is applied. |
| Watermark growth | Kept permanently (about 24 bytes per key ever seen). Deferred: revisit a retirement-scoped expiry if the key count exceeds the capacity model by an order of magnitude. |

## Open Questions

1. Approval to extend the StarRocks-required exception in `AGENTS.md` to exposure
   intelligence and its host evidence (Decision 15).
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
