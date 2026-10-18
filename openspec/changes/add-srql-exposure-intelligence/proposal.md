# Change: Add exposure intelligence to SRQL

Tracks GitHub epic #5745.

## Why

A vulnerability scanner reports that a vulnerable package is installed. ServiceRadar
already knows more than that: which process owns the package, whether that process is
listening, who it talked to, whether the peer is a known-bad address, and what sits
behind the host in the network. None of it is answerable today as one question. The
facts live in different stores (assessments in CNPG, flows and attribution in StarRocks,
topology in the graph), with different identifiers (`sr:<uuid>` device ids, IP
addresses, process tuples), and SRQL has no entity that joins them.

Operators ask these questions, and each one becomes a requirement in this change:

1. Which devices are exposed to CVE-X right now?
2. Which hosts with a KEV-listed or high-EPSS exposure talked to a threat-intel
   indicator in the last 24 hours?
3. Which vulnerable listening processes received inbound connections from the internet?
4. What is the blast radius of an exposed device through topology and BGP?
5. How does exposure break down by site, prefix tag, VLAN, owner or workload?
6. How has exposure changed over the last 90 days?

The evidence for questions 2 and 3 must not depend on NetFlow. Agents already report the
remote peer of each process's connections (on a lab deployment, about 0.5M TCP and 50k
UDP peer-bearing rows per hour from 8 agents). Host-only deployments, such as cloud,
small sites, or sites with no exporters, must get exposure answers. Where both host and
network evidence exist they corroborate each other, and their disagreement is a security
signal in its own right: a connection the network saw but a fully covered host never
reported indicates a hidden process, a rootkit, or a blinded agent.

## What Changes

- **Operator use cases first.** Six use-case requirements, each with SRQL examples and
  latency budgets, define what "done" means.
- **One observed-connection evidence set with provenance.** Host-observed (agent
  per-process connection summaries), network-observed (NetFlow, IPFIX, sFlow) and
  corroborated (both) evidence feed one hourly evidence table. Every exposure answer
  carries its provenance. SRQL exposes provenance as a column and a filter. Host-observed
  peers are evaluated against threat intelligence just like NetFlow endpoints.
- **Evasion and coverage-gap detection.** A network-observed connection that maps, after
  NAT and VIP resolution, to an agent-managed host whose agent attests complete,
  event-driven coverage for that interval, with no matching host evidence inside a
  tolerance window, raises a `network_only` signal. The reverse case is a lower-severity
  `host_only` coverage gap. False-positive controls are requirements with scenarios:
  sampling cannot create the signal by itself; unhealthy, lagging, back-pressured or
  budget-shedding agent intervals suppress; NAT, SNAT and VIP; clock skew; and shared or
  multi-homed addresses. Signals carry a deterministic confidence score, are published on
  JetStream, and become incidents through the existing alert engine. Suppressed candidates
  are recorded with their reason, so a quiet detector can be told apart from a broken one.
- **Placement: StarRocks.** The current exposure state is a Primary Key fact table keyed
  `(device_ord, cve_ord, pkg_ord)`. It is upserted from matcher assessment transitions,
  which travel on JetStream and are written by EventWriter (the transitions come from
  #5748). Async materialized views derive the roaring bitmaps (CVE -> devices, KEV devices,
  severity -> devices). They are accelerators, never the system of record. A daily bitmap
  snapshot, which is append-only and therefore safe for an Aggregate table, serves the
  trend queries.
- **Identifier dictionaries.** `device_ord` comes from `platform.device_fleet_ordinals`.
  `cve_ord` is a deterministic BIGINT (`year * 10^7 + sequence`) with a dictionary fallback
  for non-conforming identifiers. Package identity and package-version ordinals come from
  sequence dictionaries. `bitmap_hash` is never used.
- **Address dimension.** A new IP -> `device_ord` dimension with validity intervals maps
  flows and host peers to devices. Today a flow's `device_uid` is the exporter, so nothing
  maps an endpoint to a device. The flow tier also stamps per-side device ordinals and
  attribution outcomes onto flow rows at ingest, resolving each endpoint against the
  validity intervals at the flow's observation time.
- **Narrow catalog joins.** Small inventory dimensions (device names, sites, VLAN, owner,
  tags) are joined live through the existing `cnpg_platform` JDBC catalog, using two new
  flattened read-only views with column-scoped grants. Large CNPG tables (assessments,
  packages, advisories, coordinates) are never catalog-joined per query, because
  aggregates do not push down through JDBC.
- **SRQL surface.** New entities: `in:exposure`, `in:observed_connections`,
  `in:connection_discrepancies`, `in:agent_coverage`, `in:exposure_incidents`,
  `in:exposure_blast_radius` and `in:exposure_history`. A `count_distinct(device_id)`
  aggregate is evaluated as a bitmap union. Exposure pivot filters are added to `in:flows`
  and `in:attributed_flows`. All of these compose with the existing threat-intel filters
  and time windows.
- **Freshness and capacity become requirements:** at most 2 minutes from an assessment
  transition to a visible fact; at least 20k hosts and 50M active facts; per-query latency
  budgets for every showcase query; and refresh budgets for the views and snapshots.
- **Contracts consumed from prerequisites**, specified here so that exposure can be
  verified against them:
  - assessment transitions on JetStream (#5748);
  - process -> package ownership (#5752);
  - per-process connection summaries, consumed as specified by *Hosts Report Per-Process
    Connection Summaries As Evidence* in the merged `stream-flow-attribution-via-ownership-index`
    change (#5753) and not redefined here;
  - per-interval capture coverage attestations and per-side device ordinals and
    attribution outcomes on flow rows, which are new in this change and extend the merged
    `flow-attribution` requirements.
- **Delivery beyond code:** docs-site concepts and an SRQL cookbook, a demo showcase
  (dashboards and saved queries), and launch material in `carverauto/serviceradar-web`
  (a launch post, a technical deep dive, a capability page, and a comparison page). The
  launch material is gated on the capability working end to end on the demo deployment.

## Impact

- Affected specs:
  - `exposure-intelligence` (new capability; ADDED);
  - `srql` (ADDED);
  - `flow-attribution` (ADDED);
  - `endpoint-software-inventory` (ADDED);
  - `observability-signals` (ADDED).
- Affected code (implementation phases, not this proposal):
  - Core:
    - `ServiceRadar.Inventory.EndpointVulnerabilityMatcher` (transition publishing, via #5748);
    - `EndpointInventoryFleetOrdinal`, plus new package and advisory ordinal dictionaries;
    - `identity/endpoint_inventory_moves.ex` (merge tombstones retire facts);
    - a new exposure publisher;
    - a new discrepancy evaluator;
    - `NetflowSecurityRefreshWorker` (host peers feed threat-intel lookups);
    - `StatefulAlertEngine` rules for discrepancy incidents.
  - EventWriter:
    - new processors for transitions, dimensions, coverage attestations and discrepancies;
    - the #5753 host connection summary processor, extended to write evidence deltas;
    - `Processors.Flows` (per-side device ordinal and attribution outcome).
  - Warehouse DDL under `elixir/serviceradar_core/priv/starrocks/`: fact, dimension,
    evidence, coverage, discrepancy and snapshot tables, plus async MVs.
  - CNPG: migrations for the ordinal dictionaries, two catalog views, and reader grants;
    `Analytics.StarRocks.CatalogAllowlist`.
  - Netprobe and agent: coverage attestation
    (`rust/netprobe/src/attribution.rs`, `proto/agent/netprobe/v1/netprobe.proto`,
    `go/pkg/agent/push_loop_flow_attribution.go`).
  - SRQL (`rust/srql/src/parser/**`, `rust/srql/src/query/**`):
    - new entity modules, StarRocks dialect, and two-phase blast-radius execution;
    - web-ng catalog, `EntityAccess` RBAC map, and the MCP cookbook;
    - SRQL parity inventory.
  - Helm: NATS streams, subjects and permissions; EventWriter config; demo values.
  - Docs: `docs/docs/` concepts and cookbook pages; an operator runbook under `docs/`.
  - Website: `carverauto/serviceradar-web` (blog posts and marketing pages).
- Prerequisites (Phase 0): #5748, #5749, #5752, #5738 (implementation of the merged change
  #5753, including connection summaries), the IP ->
  device dimension, and the catalog views and grants. #5750 and #5751 are recommended
  database hygiene and do not gate this change.
- Related changes:
  - `add-cve-priority-context` (KEV, EPSS and due-date overlay; the fact row carries its KEV flag);
  - `add-srql-advisory-cpe-entities` (assessment entities and the exact actionable predicate this reuses);
  - `improve-threat-intel-investigation` (IOC cache and flow threat filters this composes with);
  - `stream-flow-attribution-via-ownership-index` (merged as #5753; ownership index, late
    decisions, VIP and SNAT resolution, address leases, connection summaries);
  - `add-cti-signal-coverage` (canonical CTI sightings, a later consumer);
  - `add-causal-security-detections` (its S4 "exposed CVE under live exploitation" may
    consume exposure facts; no dependency in either direction).
