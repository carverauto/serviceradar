## 1. Review and source preparation
- [ ] 1.1 Approve this proposal and its storage-destination contract; update applicable JetStream/EventWriter guidance before implementation.
- [ ] 1.2 Rebase a fresh feature worktree on current staging; audit every extraction bundle against the pinned source and current code without wholesale cherry-picks.
- [ ] 1.3 Resolve overlap with active ingestion, counter semantics, anomaly, downsampling and retention proposals; leave both withdrawn designs and private recovery artifacts untouched.

## 2. Independently shippable fixes
- [ ] 2.1 Port pending interface tasks and ICMP/availability lifecycle fixes with pagination/source-change/stale-result tests.
- [ ] 2.2 Port shared history windows and independent home-dashboard cookies, including authenticated scope and Full Screen behavior.
- [ ] 2.3 Port final requested-bounds, calendar/timezone, axis and cadence/gap fixes with formatter and JS build/test registrations.
- [ ] 2.4 Remove only the device-list Tags column and correct conditional colspans.
- [ ] 2.5 Port per-view NetFlow loading/error handling without archive routing.
- [ ] 2.6 Implement the new full-width favorited-interface chart rows and verify synthetic desktop/narrow layouts.
- [ ] 2.7 Port transaction-local JIT with commit/rollback/no-leak tests; exclude archive APIs.
- [ ] 2.8 Review and port sweep summary emission/chunk semantics with synthetic Go regressions.
- [ ] 2.9 Review and port locked inventory freshness with a concurrent transition regression.
- [ ] 2.10 Decide whether the conditional PostgreSQL CAGG bundle is needed; if yes, port schema, durable backfill, query guards and parity tests together in a separate PR. Record explicit deferral if no.

## 3. StarRocks foundation
- [ ] 3.1 Pin compatible StarRocks/operator/CRDs/images, architectures and resource profiles; approve ownership, RPO/RTO and cost envelope.
- [ ] 3.2 Add Bazel-managed synthetic shared-data and shared-nothing test environments and versioned schema/migration targets; no new shell scripts.
- [ ] 3.3 Add opt-in Helm/operator integration and Compose profile, internal transport authentication, scoped roles/secrets, redirect policy and dedicated object storage configuration.
- [ ] 3.4 Prove FE metadata persistence, CN cache loss, upgrades, object outage and full restore; publish minimum supported installation profiles.

## 4. Persistence and data model
- [ ] 4.1 Inventory every dataset writer, reader, Ash resource, background consumer and current-state side effect; finalize flows/metrics identity, partition and retention contracts.
- [ ] 4.2 Add the EventWriter destination seam preserving decoding/enrichment, demand isolation and nonnumeric/current-state writes.
- [ ] 4.3 Implement bounded Stream Load, stable identities/labels, result reconciliation, per-destination progress, explicit poison quarantine and safe ACK handling.
- [ ] 4.4 Add flow attribution update events through JetStream and monotonic partial-update semantics; test redelivery without enrichment loss.
- [ ] 4.5 Prove crash/retry/batch-regrouping/label-expiry/partial-failure behavior and late-event expiry policy with synthetic real-database tests.

## 5. Authorized queries and dashboard acceleration
- [ ] 5.1 Add backend-aware SRQL compilation and nonblocking execution with parameter binding, feature capability checks, stable result/cursor/Arrow contracts and existing authorization boundaries.
- [ ] 5.2 Add scoped query caching only where measured; verify tenant isolation and revoked-access behavior.
- [ ] 5.3 Implement time-bucket MVs/aggregate routing, freshness detection, disjoint raw edges and raw fallback for unsupported filters/classification; prove EXPLAIN selection and exact parity.
- [ ] 5.4 Migrate all flow readers including attribution/exporter cache/maps/threat paths, then all scalar-metric consumers including thresholds/anomaly/capacity/topology before their cutovers.
- [ ] 5.5 Define and implement logs/events/alert-history phase with hosted one-year retention; keep current alert state in CNPG. Specify remaining datasets separately before enabling them.

## 6. Migration, verification and rollout
- [ ] 6.1 Inventory actual source coverage privately and define historical identity mapping, backfill watermarks/checkpoints and overlap deduplication; do not resume paused recovery blindly.
- [ ] 6.2 Add bounded backfill and single-owner shadow writes; compare exact counts/totals/NULLs/sampling/rates/enrichment per interval against synthetic ground truth.
- [ ] 6.3 Run the benchmark matrix and failure/restore drills; record explicit failures, resource/cost evidence, latency percentiles and maximum passing load.
- [ ] 6.4 Run focused tests, core disposition checks and repository make test before implementation PRs; run relevant lint and GitHub checks. Prior PR evidence does not transfer.
- [ ] 6.5 Complete browser and authorized post-rollout data acceptance; validate observations occurred after rollout completion.
- [ ] 6.6 Cut over one dataset at a time only with approved consumer/coverage gates and verified rollback history; stop on mismatch.
- [ ] 6.7 Retire old writers/storage/jobs only under a separate reviewed cleanup with rechecked coverage and restore proof; update operator/user docs and retention guidance.
