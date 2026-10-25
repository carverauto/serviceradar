Every test task loads the `test-audit` skill first. Every fixture, harness and demo dataset
is synthetic: documentation address ranges (`192.0.2.0/24`, `198.51.100.0/24`,
`203.0.113.0/24`, `2001:db8::/32`), invented names, and no values exported from a running
deployment.

## 0. Prerequisites and gates

Decision 21 permits the assessment foundation in 1.x to proceed independently of
the remaining attribution gates. Tasks 0.4 and 0.5 still block traffic evidence
integration and remain required for launch; their thresholds and the full feature
scope are unchanged.

- [x] 0.1 #5748 merged: incremental, write-on-change matching that publishes assessment transitions through a transactional outbox with `transition_seq` and ordinals, per *Assessment Transitions Are Published On JetStream*. Delivered with the producer-side parts of 1.1 and 1.3; see design.md, *Implementation record*.
- [x] 0.2 #5749 fixed: superseded-package matches resolve. The read-only follow-up verified no active orphan matches and re-checked the actionable count after a subsequent successful matcher run; see design.md, *Task 0.2: read-only cleanup follow-up*.
- [x] 0.3 #5752 merged: executable -> package ownership (`ExecutableOwnership`) on FlowAttributionEvent and ProcessSnapshotEntry, per *Running Executables Resolve To Owning Packages*. Delivered by #5919 (netprobe resolver, `CAP_SYS_PTRACE` executor, proto, and core `executable_ownership` on flow attribution observations with the derived `package_identity_key`) and #5914 (rpm write-ahead-log reading, listener refresh, file-type and size hardening), with Decision 18 settled in #5921 and #5929. Evidence: `//rust/netprobe:netprobe_test` and the core `event_writer`/`other` unit shards pass on remote Bazel; the resolver, capability and identity-key tests failed before their fixes. Moving the reference onto lease owner records and connection summary rows is part of #5738 (task 0.4).
- [ ] 0.4 `stream-flow-attribution-via-ownership-index` (merged as #5753) implemented and live on the lab. It provides the ownership index, late decisions, address presence and the per-process connection summaries (*Hosts Report Per-Process Connection Summaries As Evidence*, stored in `host_connection_summaries`). #5738 carries `ExecutableOwnership` on lease owner records and connection summary rows. This change consumes those summaries and does not redefine them.
- [ ] 0.5 Measure on a lab deployment and record the results rounded in design.md, with no hostnames, addresses or cluster names:
  - distinct evidence keys per host per hour;
  - network evidence pre-aggregation ratio against flow rows, per exporter (gate: <= 25%);
  - host evidence pre-aggregation ratio against summary rows, per host (gate: <= 25%).
  If the network evidence gate fails, switch network evidence to an async view over flows before 3.x.
- [x] 0.6 Spike on a scratch StarRocks with 50M synthetic facts. Gates:
  - Primary Key Stream Load with `merge_condition` (reordered and duplicate transitions);
  - view refresh <= 60 s;
  - use case 1 rows <= 500 ms and counts <= 1 s.
- [x] 0.7 Widen `EndpointInventoryFleetOrdinal` allocation to every non-service device the address publisher emits. Confirm u32 headroom.
- [x] 0.8 CNPG migration: the `exposure_device_catalog` and `exposure_device_tags_catalog` views, column-scoped grants to `serviceradar_starrocks_reader` (guarded on the role existing; never `LOGIN`), `CatalogAllowlist` entries, and allowlist tests that reject the large tables.
- [x] 0.9 Obtain approval to extend the StarRocks-required exception to exposure intelligence (design Decision 15). Update `AGENTS.md` only after approval. Approved by the product owner on [2026-10-18](https://github.com/carverauto/serviceradar/issues/5745#issuecomment-6255360407); the exception is recorded in `AGENTS.md`.

## 1. Dictionaries, fact table and transitions
- [ ] 1.1 CNPG migrations: `exposure_fact_watermarks` (key, terminal state, new sequence), `device_fleet_ordinals.retired_seq` and lifecycle publication state, `exposure_advisory_ordinals` (starting at 10^12), `exposure_package_ordinals`, `exposure_package_version_ordinals`, the `transition_seq` sequence (drawn under the assessment row lock and stored on the assessment row), and `transition_xid` on outbox rows. Add a CVE ordinal function with unit tests at the 10^7 boundary.
- [x] 1.2 StarRocks DDL under `elixir/serviceradar_core/priv/starrocks/`: `exposure_facts`, `exposure_cve_dim`, `exposure_package_dim` and `exposure_transitions_log` (migration 0032; storage contract checks run in the disposable SrqlParity fixture). Migration 0033 adds `transition_seq` to both dimensions.
- [ ] 1.3 NATS: the transitions and `exposure.dimensions.*` subjects, stream limits, and Helm permissions (core publishes, EventWriter consumes). Transition transport is delivered. Decision 22 adds CVE/package publication, including a daily EPSS refresh; remote unit and warehouse-boundary validation passed; hosted integration validation remains required. Address publication remains in 2.1.
- [ ] 1.4 EventWriter `ExposureTransitions` and `ExposureDimensions` processors: Stream Load of complete after-images with `merge_condition = transition_seq`, resolution as a state change, and transition log appends. The transition processor is delivered. Decision 22 adds CVE/package dimension ingestion; remote unit and warehouse-boundary validation passed; hosted integration validation remains required. Address ingestion remains in 2.2.
- [ ] 1.5 Merge and deletion handling: `device_retired` with a new sequence from `endpoint_inventory_moves.ex` and device deletion; assessment-row deletion as a `resolved` transition with a new sequence; StarRocks `exposure_retired_ordinals` and cross-replica lifecycle fencing; explicit sequenced restoration with the same ordinal, bounded durable republication, stale-lifecycle drops and future-lifecycle retries (Decision 23). Grep for every writer of `device_fleet_ordinals.tombstoned` and of device deletion, not only the obvious one.
- [ ] 1.6 Snapshot generation fenced by the recorded `pg_current_snapshot()` (start and end markers, terminal watermarks for every non-actionable fact key from assessment rows and `exposure_fact_watermarks`, lifecycle markers retaining retirement watermarks, restoration readiness, sequence/state/content comparison and source-locked repair under a new sequence, finalize rule over `transition_xid` visibility, live transitions not visible in the snapshot applied in any order) and the daily per-device reconciliation with exported mismatch counts. Extend producers and repair to share full fact-key serialization across creation, update and deletion, including absent assessments; when both source records are absent, atomically record a terminal watermark and outbox transition under a new sequence greater than the stored warehouse fact (Decision 20).
- [ ] 1.7 Resolved facts kept as permanent sequence watermarks; older transitions rejected, identical equal-sequence replay allowed, changed content assigned a new sequence, and snapshot markers preserved; daily compaction of tombstone payloads resolved more than 7 days ago; health alerts on outbox relay age (10 minutes) and transitions stream `max_age` (7 days).
- [ ] 1.8 Tests per scenario of *Exposure State Is A Primary Key Fact Table Fed By Assessment Transitions*, *Exposure Identifiers Use Collision-Free Dictionaries* and *Exposure Is Rebuildable And Reconciled Against The Assessment Store*. Verify fact-table ownership through the transition interface: a published synthetic transition yields its fact row, and a rolled-back assessment change yields none. Include a snapshot test with a resolving transaction in flight while the snapshot is read, a warehouse-restore test with a pending older redelivery, a test delivering an older transition after compaction, the deleted-versus-active-row test, missing-source resolution and concurrent re-creation in both delivery orders, a source recheck that finds a newly created assessment, retirement-before-first-delivery, restore/unmerge, reordered lifecycle markers, future-lifecycle retry and cross-consumer retirement-race tests, a reordered after-image test, and a reconciliation test that fails when a fact is removed out of band.

## 2. Address dimension and flow stamping
- [ ] 2.1 Address publisher: inventory address changes and agent address leases -> `exposure.dimensions.address`, with complete interval rows carrying `interval_seq`, the shared flag, the attested flag, and prefix tags and site from the native prefix lookup.
- [ ] 2.2 StarRocks `exposure_device_addresses` and its EventWriter processor.
- [ ] 2.3 Flow-tier in-memory address validity history fed from the stream (retained for the maximum accepted flow delay plus the late window, with metrics including the `outside_history` count), endpoint resolution at the flow's observation time, plus new flow columns `src_device_ord`, `dst_device_ord`, `src_device_resolution`, `dst_device_resolution`, `src_attribution_outcome` and `dst_attribution_outcome`. Late stamps update the outcome and re-resolve the device with the same lookup. Address watches keyed by `(partition, ip)` for the late window, decision updates on address and ownership changes from one per-flow decision sequence carrying complete after-images, and the `address_update_after_cutoff` count. No backfill.
- [ ] 2.4 Tests per scenario of *Flows And Host Evidence Map To Devices Through An Address Dimension* and *Flow Rows Record Per-Side Attribution Outcome And Device Ordinal*, including the delayed flow after readdressing, the flow that arrives before its address update, and ownership and address decisions delivered out of order.

## 3. Evidence
- [ ] 3.1 Extend the #5753 `host_connection_summaries` processor to also write evidence deltas. Rows merged to `service` or `overflow` become `peer_scope = unknown` evidence and are counted.
- [ ] 3.2 Flow processor evidence deltas written from each side's final stamp at the late-window cutoff, with per-batch pre-aggregation -> `observed_connections_hourly`, classifying `peer_scope` against local CIDRs.
- [ ] 3.3 Admit host-observed internet peers to the threat-intel lookup queue, deduplicated against flow endpoints.
- [ ] 3.4 Add the `exposure_evidence` and `exposure_history` retention datasets as database-backed settings.
- [ ] 3.5 Tests per scenario of *Observed Connections Form One Evidence Set With Provenance*, *Exposure Answers Do Not Require Network Flow Exporters* and *Host-Observed Peers Are Evaluated Against Threat Intelligence*.

## 4. Bitmap views and history
- [ ] 4.1 Async views `exposure_cve_devices_mv`, `exposure_risk_devices_mv` and `exposure_device_summary_mv` (60 s refresh), with refresh age and duration metrics.
- [ ] 4.2 `exposure_daily` Aggregate table and the daily snapshot job. History filters are limited to the retained dimensions and the current-membership slices.
- [ ] 4.3 Verification that compares each view's counts with direct fact counts, with a failure branch.
- [ ] 4.4 Tests per scenario of *Exposure Bitmaps Are Derived Views, Never The System Of Record* and *Exposure Trend Is Answerable Over Time*.

## 5. SRQL
- [ ] 5.1 Parser: the new entities (one canonical name each, no aliases), the `count_distinct(device_id)` aggregate, and the exposure, evidence, outcome and device-id filters on `flows` and `attributed_flows`.
- [ ] 5.2 StarRocks dialect for `in:exposure`, `in:observed_connections`, `in:exposure_history`, the flow pivots, view selection by staleness, and `as_of` reporting.
- [ ] 5.3 Two-phase execution for `in:exposure_blast_radius`: seed cap, depth and node caps, BGP prefixes through BMP events and the address dimension, and truncation flags.
- [ ] 5.4 `starrocks_required`, `catalog_unavailable` and `epss_unavailable` states; parameterization; window caps.
- [ ] 5.5 web-ng SRQL catalog, the `EntityAccess` permission map (every new entity), the MCP SRQL cookbook, viz metadata, and the SRQL parity inventory entries (StarRocks-only).
- [ ] 5.6 Tests per scenario of the `srql` delta and of the six use-case requirements. Assert the compiled SQL for each showcase query.

## 6. Coverage attestation and discrepancy detection
- [ ] 6.1 Netprobe and agent: per-interval coverage attestations, published after the interval's summary rows are acknowledged, carrying the aggregation level reached and the event-budget shed counts. Core publishes them on `flows.connections.coverage` in the `flow_connections` stream (proto, NATS subject and permissions). Bump the netprobe add-on manifest version and Bazel `NETPROBE_VERSION` together.
- [ ] 6.2 StarRocks `agent_capture_coverage` and its processor.
- [ ] 6.3 Discrepancy candidate publishing from the flow's home shard at the late-window cutoff (never for flows finalized early or with agent-provided attribution; deduplicated).
- [ ] 6.4 Sharded `DiscrepancyEvaluator`: waits for the evaluation point of the candidate's hour, attestations and evidence, applies the ordered controls, records suppressions from the closed reason vocabulary, scores, and publishes on `exposure.discrepancies`.
- [ ] 6.5 Hourly `host_only` evaluation at each hour's evaluation point (one evidence read shared with `network_only`), including the hour-boundary scenario, over expected-coverage rules, with exporter health and the sampling expectation, and its own confidence (`H x X x P`) and threshold.
- [ ] 6.6 `connection_discrepancies` table and processor; OCSF Detection Finding emission.
- [ ] 6.7 SRQL `in:connection_discrepancies`, `in:agent_coverage` and `in:exposure_incidents`.
- [ ] 6.8 Tests per scenario of every evasion, coverage-gap and false-positive control requirement. Each suppression reason is covered by a test that produces it.
- [ ] 6.9 Controlled verification on the lab, gating on rows written after the rollout finished:
  - a stimulus that withholds one known connection from a simulated agent's summaries produces exactly one signal;
  - the same stimulus with sampled-only evidence produces `sampled_only`.

## 7. Alerting
- [ ] 7.1 Stateful alert rules and incident fingerprints for discrepancy findings, with default thresholds 0.85 (`network_only`) and 0.75 (`host_only`).
- [ ] 7.2 Tests per scenario of the `observability-signals` delta.
- [ ] 7.3 Follow-up, not in this change: operator-configurable alert rules on exposure conditions (for example a new KEV exposure), proposed separately.

## 8. Capacity verification
- [ ] 8.1 Synthetic load harness using only invented data: 20k hosts, 50M facts, 50k CVEs, transitions, summaries, flows and addresses.
- [ ] 8.2 Runs against every target of *Exposure Meets Fleet-Scale Capacity Targets* and *Exposure Freshness Meets Bounded Staleness Targets*. Record the results rounded in design.md.

## 9. Documentation
- [ ] 9.1 Docs site concepts page `docs/docs/exposure-intelligence.md`: exposure versus installed-package findings, evidence provenance, evasion signals and their controls, and freshness. Use "ServiceRadar Atlas" for the topology map in public text.
- [ ] 9.2 SRQL reference entries for every new entity, field and aggregate. Add a cookbook section with one recipe per use case plus evasion triage and pivots.
- [ ] 9.3 Operator runbook under `docs/`: the reference warehouse profile, snapshot and reconciliation, view staleness, expected-coverage rules, and reading the suppression reasons.

## 10. Demo showcase (on the demo deployment)
- [ ] 10.1 Demo data path: synthetic simulators produce inventory, flows and host summaries using documentation ranges only.
- [ ] 10.2 Saved SRQL queries for each use case, evasion triage and the pivots.
- [ ] 10.3 Dashboards: exposure overview (KEV, critical, by site), internet-reachable vulnerable listeners, IOC contact, ServiceRadar Atlas blast-radius overlay, a 90-day trend, and evasion incidents.
- [ ] 10.4 End-to-end verification on demo with the controlled evasion stimulus. Record the query outputs and timestamps after the rollout finished.

## 11. Launch material (gated on 10.4 passing)
- [ ] 11.1 `carverauto/serviceradar-web`: a launch blog post.
- [ ] 11.2 `carverauto/serviceradar-web`: a technical deep dive on bitmaps over device ordinals, evidence provenance and evasion detection.
- [ ] 11.3 `carverauto/serviceradar-web`: an exposure intelligence capability page, and a comparison page against installed-package scanners.
- [ ] 11.4 Screenshots and examples taken from the demo deployment only, with synthetic data.
