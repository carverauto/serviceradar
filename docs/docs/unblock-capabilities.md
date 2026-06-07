# Capability Unlocks: A Better Causal Engine from the Start

> **Companion to** [Integration-assessment.md](./Integration-assessment.md).
> That document establishes what V1 of the causal engine can ship against
> ServiceRadar's existing schema. This one inventories what additional
> capabilities V1 *gains* when the seven identified gaps are closed. Gaps
> are ranked by net utility, weighted toward cross-domain reach.
>
> **Premise.** V1 ships against today's data schema. Every gap closed before or
> during V1 makes the engine measurably better at the moment it goes live.
> The pre-V1 audits (Gap B, Gap G) cost days. The cross-domain bridge
> (Gap A) is the qualitative leap. Together they raise the floor of what
> V1 means.

---

## How to read this document

For each gap, four pieces:

- **Domains bridged.** Which previously-disjoint signal domains the closed
  gap connects. Cross-domain reach is the primary ranking driver.
- **New capability.** What the engine can do once the gap is closed that
  it cannot do today.
- **Why ranked here.** The trade-off between unlock size, engineering cost,
  and gating effect on other work.
- **How to close.** Concrete steps. Schema diffs, identifier matching,
  audit queries, code touchpoints. Each gap names every join key it needs
  and every column it adds.

The list is sorted by net utility. Skim the ranking, read the gap that
matches the work you can fund, and treat the rest as the surrounding
investment landscape.

---

## Ranking criterion

How many cross-domain causaloids each closed gap enables, with single-domain
unlocks ranked below cross-domain ones of comparable engineering cost.
Cross-domain bridges are where DeepCausality's hypergraph model pays for
itself. Within a single domain, the engine can reason; across domains, the
engine can reason about *consequences*.

---

## Rank 1. Gap A: service to flow bridge

**Domains bridged.** Netflow ↔ OTEL ↔ `service_status` ↔ `ocsf_devices`.
Four domains.

**New capability.**

- Service dependency graph derived from OTEL spans, where parent/child
  pairs across services become directed edges. Runtime-observed; stays
  current.
- C10 (blast radius) upgraded from IP granularity to service granularity.
- A new causaloid class: "Service A latency rising ⟹ predict degradation
  for all services with observed call edges → A."
- Trace-anchored root cause: when N services degrade, the OTEL graph
  identifies the *minimum upstream set* that explains all N.

**Why rank 1.** The engine's reach jumps from infrastructure to *what the
business delivers*. Engineering cost is low if OTEL traces already carry
span parent/child IDs. The bridge is a derivation, not a schema change.
Highest leverage-per-effort in the entire list.

**How to close.** Two halves: service-to-service derivation, and
service-to-flow binding.

1. *Audit `otel_traces` and `otel_trace_summaries`.* Confirm the columns
   carry `service_name` (or `resource.service.name`), `trace_id`, `span_id`,
   and `parent_span_id`. The standard OTEL data model has all four, but
   ServiceRadar's normalization may have flattened or renamed them. If
   present, derive directed service-to-service edges by self-joining spans
   within the same `trace_id`:

   ```sql
   SELECT parent.service_name AS caller,
          child.service_name  AS callee,
          count(*) AS observed_calls,
          avg(child.duration_ms) AS avg_latency
   FROM otel_traces child
   JOIN otel_traces parent
     ON parent.span_id = child.parent_span_id
    AND parent.trace_id = child.trace_id
   WHERE parent.service_name <> child.service_name
   GROUP BY 1, 2;
   ```

   This is the *service dependency graph*. No schema change required if the
   columns exist.

2. *Bind services to IP and port.* The seam between `service_status` and
   `netflow_metrics` needs a `(service_id, ip, port, protocol)` mapping.
   Two options ranked by cost:

   - **Agent self-report (preferred).** Agents already know what they
     monitor and where it listens. Extend the agent's `service_status`
     submission to include the listen address. Add three columns to
     `service_status` (or a new `service_endpoints` table keyed on
     `(gateway_id, agent_id, service_name)`): `listen_ip inet`,
     `listen_port integer`, `protocol text`.
   - **Operator declaration.** A small CRUD surface (Ash resource) lets
     operators bind a service to its IP and port when self-report is not
     possible.

3. *Join netflow to services.* Once the mapping exists:

   ```sql
   SELECT s.service_name AS callee,
          n.src_ip       AS caller_ip,
          sum(n.bytes)   AS bytes
   FROM netflow_metrics n
   JOIN service_endpoints s
     ON n.dst_ip = s.listen_ip
    AND n.dst_port = s.listen_port
    AND n.protocol = s.protocol
   GROUP BY 1, 2;
   ```

   `caller_ip` resolves to a device via `ocsf_devices.ip`, and from there
   to any service that device hosts. Now C10 runs at service granularity.

**Identifier glue.** The chain is
`otel.service_name → service_endpoints.service_name → (ip, port) →
netflow_metrics → ocsf_devices.ip → agent → service`. Every join key
already exists in the schema except `service_endpoints.(ip, port)`. That
is the only net-new data to populate.

---

## Rank 2. Gap G: articulation points and bridges (closing upstream)

**Domains bridged.** Within network topology, but unlocks a
*standing-predictive* output class that no other gap enables.

**New capability.**

- C5 and C5b ship as single library calls.
- Blast-radius enumeration: for each cut vertex or edge, the connected
  components after removal are the affected sets. Standing predictions
  ranked by component size.
- Composition with `pathway_betweenness_centrality`. Articulation points
  partition the *graph*; pathway-restricted centrality partitions
  *observed traffic*. Operators prioritize differently.
- Composition with C1 (virt cascade). An articulation vertex that is also
  a virt host has blast radius equal to its component ∪ its hosted guests.
- Planning-facing output: "if we put D in maintenance, which subnets and
  services lose reachability?" Same algorithm, different framing.

**Why rank 2.** Standing-predictive output is the most operationally
valuable class. It answers "what should I worry about right now?" without
anything having to fail. Implementation cost is roughly 200 LOC upstream,
not a ServiceRadar change.

**How to close.** Upstream PR to `deepcausality-rs/deep_causality`,
`ultragraph` crate. No ServiceRadar-side schema or data work required.

1. Implement Tarjan's algorithm on `CsmGraph` (the frozen state). One DFS
   pass over the CSR adjacency. The biconnected-components decomposition
   is the most general form and subsumes both outputs.
2. Add three trait methods to `StructuralGraphAlgorithms`:

   ```rust
   fn articulation_points(&self, directed: bool) -> Result<Vec<usize>, GraphError>;
   fn bridges(&self) -> Result<Vec<(usize, usize)>, GraphError>;
   fn biconnected_components(&self) -> Result<Vec<Vec<usize>>, GraphError>;
   ```

3. Match the existing API convention from `betweenness_centrality(directed,
   normalized)`. Classical articulation-point and bridge detection are
   defined on undirected graphs, which matches ServiceRadar's
   `CONNECTS_TO` physical-link semantics.
4. Tests against known graphs (Tarjan's original example, a Petersen
   graph, a star, a complete graph, two disjoint cliques connected by a
   bridge).
5. Bench against `betweenness_centrality` for comparison.

**Identifier glue.** None. ServiceRadar passes its existing
`(node_id, edge_list)` to ultragraph and receives back lists of indices
into the same node space. No new keys, no joins.

---

## Rank 3. Gap F: structured physical components

**Domains bridged.** SNMP timeseries ↔ device inventory ↔ AGE topology ↔
(eventually) redundancy modeling.

**New capability.**

- Per-component health for physical hosts (PSU, fan, temp, disk).
- Physical-host containment causaloid at parity with C1 and C2.
- Substrate for the redundancy story. Redundancy groups become hyperedges
  over component entities. The PSU and RAID examples from the original
  integration doc become writable, *after* this gap is closed.
- Vendor-neutral component model with OID template normalization.

**Why rank 3.** Largest absolute new substrate, but also the largest
engineering cost (schema design, SNMP collector work, OID template
curation, ingest pipeline change). High payoff, slow delivery, with
cross-domain reach contained to physical infrastructure.

**How to close.** OpenSpec change proposal per repo convention. Four parts.

1. *Schema.* New table `platform.device_components`:

   ```sql
   CREATE TABLE platform.device_components (
     id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
     device_uid      text NOT NULL REFERENCES platform.ocsf_devices(uid),
     component_type  text NOT NULL,        -- psu | fan | temp_sensor | disk | memory_module | nic
     component_index integer NOT NULL,     -- stable per device + type
     parent_index    integer,              -- nests components (e.g., disk-in-bay)
     model           text,
     vendor          text,
     serial          text,
     health          text NOT NULL,        -- controlled vocabulary, see Gap C
     attributes      jsonb DEFAULT '{}',
     first_seen_time timestamp,
     last_seen_time  timestamp,
     UNIQUE (device_uid, component_type, component_index)
   );
   ```

2. *Identity matching from SNMP.* The cross-vendor standard is
   **ENTITY-MIB (`entPhysicalTable`)**. Every component is a row with
   `entPhysicalIndex` (the stable index), `entPhysicalClass` (mapping to
   `component_type`: `powerSupply(6)`, `fan(7)`, `sensor(8)`,
   `module(9)`, `port(10)`), `entPhysicalDescr`, `entPhysicalSerialNum`,
   `entPhysicalModelName`, `entPhysicalContainedIn` (mapping to
   `parent_index`). Vendors that do not implement ENTITY-MIB fully (some
   appliances, older gear) need per-vendor MIB overlays: Cisco
   `CISCO-ENVMON-MIB`, Juniper `JUNIPER-MIB`, Dell `iDRAC`, HP `cpqHe*`.
   Health source: `entSensorValue`, `cefcFanTrayStatus`,
   `cefcModuleOperStatus`, vendor-specific OIDs.

3. *Collector.* Extend the SNMP polling path to walk `entPhysicalTable`
   first, populate `device_components` rows, then emit per-component
   health into `health_events` (joined by `entity_type='component'`,
   `entity_id=device_components.id`). Replaces the current pattern of
   anonymous `timeseries_metrics` rows for environmental data. Keep
   `timeseries_metrics` for the numeric sample stream; reference
   `device_components.id` in `metadata`.

4. *AGE edges.* Project `device_components` into the AGE graph as
   `Component` vertices, with `Device CONTAINS Component` edges. Each
   `Component` carries `component_type` and `health` as properties. The
   existing `topology_graph.ex` projection extends with one new MERGE
   pattern per component.

**Identifier glue.** Primary key is
`(device_uid, component_type, component_index)`. ENTITY-MIB's
`entPhysicalIndex` is the source for `component_index` where the MIB is
implemented. For vendors without ENTITY-MIB, the collector synthesizes a
stable index from a deterministic hash of `(oid_subtree, position)`.

---

## Rank 4. Gap B: `capacity_bps` coverage audit

**Domains bridged.** Netflow (load) ↔ AGE topology (capacity).

**New capability.**

- C6 ships reliably across all edges with populated capacity.
- Time-to-saturation projections become a standing predictive output
  across the entire network surface.
- Composes with C9 (shared-hop bottleneck). A hop that is both shared
  *and* approaching capacity is a sharper prediction than either alone.

**Why rank 4.** Narrow cross-domain reach, but trivially cheap to close
(audit task, not schema change). Could legitimately ship before V1.

**How to close.** A measurement task with a small backfill.

1. *Trace the source.* `GodViewStream` reads `capacity_bps` on edges. Walk
   the projection in `topology_graph.ex` and the runtime graph builder to
   find which table or AGE edge property is read. Most likely candidates:
   `discovered_interfaces.if_high_speed` or `if_speed`, possibly an AGE
   edge property set during projection, possibly `interface_settings`.
2. *Measure coverage.* Once the source is known, run:

   ```sql
   SELECT count(*) AS total,
          count(*) FILTER (WHERE capacity_bps IS NULL) AS null_count,
          count(*) FILTER (WHERE capacity_bps = 0) AS zero_count,
          count(DISTINCT device_uid) AS distinct_devices
   FROM <source_table>;
   ```

   Repeat partitioned by `evidence_class` and `confidence_tier`. The
   result tells you whether C6 is reliable on `direct-physical` edges only
   or across the broader topology.
3. *Backfill the gap.* SNMP-derived `if_high_speed` (ifHighSpeed OID
   `1.3.6.1.2.1.31.1.1.1.15`) is the standard source. For inferred or
   logical edges where no SNMP value exists, accept operator declaration
   via `interface_settings.capacity_bps_override` (one new column).
4. *Document the contract.* Mark edges without populated capacity as
   ineligible for C6. The God-View envelope already carries
   `telemetry_eligible`, which is the natural place to encode this.

**Identifier glue.** None new. Join keys (`device_uid`, `if_index`,
`interface_id`) already exist.

---

## Rank 5. Gap C: health-state controlled vocabulary

**Domains bridged.** Across entity types rather than across signal domains.

**New capability.**

- C11 generalizes uniformly across devices, services, components, and BGP
  peers.
- State-transition causaloids become a primitive the engine recognizes
  uniformly.
- Multi-state verdict output closes the producer/consumer loop on health
  vocabulary.

**Why rank 5.** Real cross-entity reach, but the unlock is *quality*
rather than new capability. Moderate engineering cost (audit, define,
migrate).

**How to close.** Three steps.

1. *Audit existing values.*

   ```sql
   SELECT entity_type, new_state, count(*) AS occurrences
   FROM platform.health_events
   GROUP BY 1, 2
   ORDER BY 1, 3 DESC;
   ```

   This is the unconstrained alphabet the system is actually using today.
2. *Define the controlled vocabulary.* Proposed set:
   `healthy | degrading | degraded | reduced-redundancy | failing | failed
   | unknown`. Seven values, ordered by severity. Each maps to a small
   integer for cheap comparisons. Same vocabulary applies to devices,
   services, components, and BGP peers.
3. *Migrate.* Add a check constraint, or convert `new_state` to a Postgres
   ENUM. Provide a lookup table mapping legacy free-text values to the
   controlled set. Update every emit site (the SNMP collector, the agent
   health reporter, BGP/BMP handlers, the `CausalSignals` processor) to
   use the controlled values.
4. *Align engine output.* The causal-engine emitter publishes verdicts
   using the same vocabulary. Symmetry between input and output closes the
   producer/consumer loop without translation.

**Identifier glue.** The `health_events.(entity_type, entity_id)`
polymorphic key already exists. The vocabulary change is value-side only,
not key-side.

---

## Rank 6. Gap E: OOB gateway flag

A narrow false-positive class for C3. Only matters in deployments where
gateways are not on a dedicated OOB network.

**How to close.** One column, one migration.

```sql
ALTER TABLE platform.gateways
  ADD COLUMN network_class text NOT NULL DEFAULT 'in-band'
    CHECK (network_class IN ('in-band', 'out-of-band', 'management'));
```

Update the gateway registration flow (Ash resource action) to accept the
class at create time. Default existing rows to `in-band`. C3 reads the
column when classifying root cause: a gateway flagged `out-of-band` whose
observed devices all become unavailable points to the devices' shared
in-band path, not to the gateway itself.

**Identifier glue.** None. The flag is a property of the existing gateway
identity.

---

## Rank 7. Gap D: reverse `MANAGES` edge

Pure ergonomics. A C4 performance improvement only. No new causaloids
unlocked.

**How to close.** Either add a reverse edge in AGE, or add a Postgres
index. The AGE approach is more consistent with how other relationships
are projected. In `topology_graph.ex`, where the `MANAGED_BY` MERGE
already runs, add the inverse:

```
MERGE (mgmt:Device {id: '...mgmt_id...'})
MERGE (child:Device {id: '...child_id...'})
MERGE (mgmt)-[r:MANAGES]->(child)
```

The relational alternative is a single Postgres index on
`ocsf_devices(management_device_id)`, which is faster to ship if AGE
projection changes are blocked.

**Identifier glue.** None. The pair `(management_device_id, uid)` already
exists in `ocsf_devices`. The change is index or edge direction only.

---

## Why cross-domain bridges dominate

Today's signal domains are largely disjoint. Inventory reasons about
itself; telemetry reasons about itself; routing about itself; flow about
itself; service about itself; application about itself; virtualization
about itself. The V1 causaloids already bridge some of these (C3 bridges
inventory and service health; C7 bridges inventory and service; C8 bridges
routing and reachability; C10 bridges flow and service availability), but
every bridge has a seam. It uses IPs where it would prefer service IDs, or
agent presence where it would prefer application health.

**Closing Gap A removes the largest such seam.** OTEL traces and netflow
data become *the same dependency graph at different granularities*, and
`service_status` becomes the *health overlay* on that graph. This is the
configuration where DC's hypergraph machinery earns its keep: cross-domain
inference whose conclusions cannot be reached by any single-domain
reasoner.

**Closing Gap F is the second-largest unlock**, but it deepens a single
domain. It is the natural follow-on once cross-domain reasoning is in
place, because component-failure predictions become *more* valuable when
the engine can also trace their consequences through the service
dependency graph that Gap A provides.

---

## Recommended sequencing

For a stronger V1 at launch, close in this order:

| When | Gap | Cost | What V1 gains at launch |
|---|---|---|---|
| Pre-V1 (days) | **G:** articulation points, bridges | ~200 LOC upstream | C5 and C5b ship as library calls; standing single-point-of-failure predictions on day one. |
| Pre-V1 (days) | **B:** `capacity_bps` audit | Audit + small backfill | C6 trustworthy across the network surface, not just a subset of edges. |
| Concurrent with V1 (weeks) | **A:** service to flow bridge | Mapping table + OTEL audit | Service-level reasoning replaces IP-level reasoning. C10 becomes operationally meaningful. |
| Post-V1 (months) | **C:** health vocabulary | Audit + migrate | Multi-state reasoning generalizes across entity types. |
| Post-V1 (multi-quarter) | **F:** structured components | OpenSpec + collector work | Physical-host containment at parity with virtualization; substrate for redundancy modeling. |
| When convenient | **E:** OOB flag | One column | C3 false-positive reduction in mixed OOB deployments. |
| When convenient | **D:** reverse `MANAGES` | Index or MERGE | C4 graph-side performance. |

Closing G and B before V1 ships costs days and changes the launch
deliverable from "C6 sometimes, C5 not at all" to "C5, C5b, C6 all live."
That alone is worth the budget. Closing A during V1 ships service-level
reasoning in the same window as the engine itself, which is where the
qualitative narrative of the engine lives.
