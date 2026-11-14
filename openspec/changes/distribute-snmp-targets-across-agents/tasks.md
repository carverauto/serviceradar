## 0. Prerequisite agent fixes (land first, independently)
- [ ] 0.1 Size SNMP aggregator ring buffers to the samples expected between drains and grow lazily, instead of preallocating `MaxPoints` (1,000) samples per series (`go/pkg/agent/core/ring.go:36`, `go/pkg/agent/snmp/service.go` `initializeTarget`, `go/pkg/agent/snmp_service.go:792`)
- [ ] 0.2 Apply SNMP config changes by diffing targets (`SNMPService.AddTarget`/`RemoveTarget`) instead of `Stop()` plus `Start()` of the whole service (`go/pkg/agent/snmp_service.go` `ApplyProtoConfig`, `checkConfigUpdate`), preserving counter-delta state of unchanged targets
- [ ] 0.3 Replace the per-target long-lived connected UDP socket and three goroutines with a jittered scheduler and a bounded worker pool, so sockets follow in-flight requests
- [ ] 0.4 Remove the service-wide lock from the per-data-point path (`SNMPService.handleDataPoint` takes `s.mu` per point; `DrainMetrics` holds it across every aggregator): per-target state, drain by swap; this is the measured 40,000 points/s ceiling
- [ ] 0.5 Stop holding a 64 KiB `gosnmp` receive buffer per target (one per connection, `rxBufSize`); covered by 0.3 if connections are pooled per worker
- [ ] 0.6 Stop one target's init failure from aborting `SNMPService.Start` for every target (`go/pkg/agent/snmp/service.go:163`)
- [ ] 0.7 Re-run the capacity benchmark (design.md "Measurements") against the fixed poller and record the per-agent defaults it supports

## 1. Shared placement seam (`target-placement`)
- [ ] 1.1 Placement table keyed by (workload, target key, agent) with state, authority generation, reason, per-agent revision, credential digest, and last success/failure; tombstones retained until the agent acknowledges a later revision
- [ ] 1.2 `ServiceRadar.Edge.TargetPlacement` behaviour: eligible agents, cost of a target, capacity of an agent, redundancy; sticky weighted rendezvous selection; reasons enumerated
- [ ] 1.3 Per-agent revision allocation (atomic, never repeated or lowered) and revision-history compaction floor
- [ ] 1.4 Placement pass worker (Oban, idempotent, bounded moves per pass), plus the per-target fast path for single-device events
- [ ] 1.5 Liveness lease input from control-stream session state; `owner_lost` handling
- [ ] 1.6 Coverage accounting: `uncovered` states with reasons, telemetry `[:serviceradar, :target_placement, :coverage]`, alert rule

## 2. SNMP placement
- [ ] 2.1 Add `placement_mode` (`distribute` | `replicate`, default `distribute`) and `redundancy` (default 1) to `SNMPProfile`; refuse `replicate` without pinning
- [ ] 2.2 Resolve each device to exactly one profile (priority, then default) in the placement pass, reusing `SrqlTargetResolver.resolve_for_devices/3` and `SNMPCompiler.reduce_target_pages/4`
- [ ] 2.3 SNMP cost model (data points per second: scalar OIDs plus walk rows plus availability, per interval; requests tracked for pacing) and capacity from agent reports
- [ ] 2.4 Explicit `SNMPTarget` rows placed per the decision on design.md open question 3
- [ ] 2.5 Reachability rule: consecutive failures, per-target agent backoff, candidate limit, `unreachable_on_owner` moves
- [ ] 2.6 Replace `SNMPCompiler.affected_agents_for_device/1` fleet invalidation and the `device_snmp_config` dependency-catalog entry with per-device placement re-evaluation

## 3. Delivery
- [ ] 3.1 Proto: `SyncSNMPTargets` server-streaming RPC, `SNMPTargetPage` (entries with op, target, generation; final marker; revision; snapshot flag; payload digest), control-stream `SNMPTargetRevisionHint`, `SNMPConfig.profiles`
- [ ] 3.2 Gateway: serve pages from core, reuse `ConfigChunks` budgets and digest validation; config poll response reports current revision
- [ ] 3.3 Core: page producer resolving credentials at serve time through `CredentialResolver`; credential change advances affected rows' revisions
- [ ] 3.4 Agent: advertise `snmp-target-deltas:v1`; pull on hint and on poll; validate all pages before applying; acknowledge applied revision and generation
- [ ] 3.5 Agent config generator: carry profile definitions only for delta-capable agents; compile placed share for legacy agents; version hash excludes delta-delivered targets

## 4. Agent capacity reporting
- [ ] 4.1 Report per-window SNMP poller statistics (targets, polls due, polls on time, data points, requests sent, scheduling lag) on the control stream
- [ ] 4.2 Per-target outcome summary (last success, consecutive failures) in the acknowledgement path for the reachability rule

## 5. Settings and retirement
- [ ] 5.1 Redefine `edge_pipeline_settings.snmp_max_targets` as the per-agent placement ceiling across profiles; update `PipelineSettings` docs and code default from 0.7; add the legacy-ceiling code default
- [ ] 5.2 Delete `ServiceRadar.SNMPProfiles.TargetLimit`, `Changes.CheckTargetLimit`, the `[:serviceradar, :snmp, :target_limit_exceeded]` event, and their tests and UI message
- [ ] 5.3 Update `docs/docs/snmp.md` (limit section) to describe placement, ceilings and coverage

## 6. Operator surfaces
- [ ] 6.1 Capacity view: per partition and per agent capacity, load, measured rate, lateness; per profile placed, uncovered and under-replicated counts with reasons
- [ ] 6.2 SNMP profile form: placement mode, redundancy, projected coverage before save
- [ ] 6.3 Device detail: which agent polls this device and why (reason, since)

## 7. Migration
- [ ] 7.1 Migration adds profile columns with defaults per the answers to design.md open questions 1 and 2; no credential re-entry; explicit targets keep their rows
- [ ] 7.2 First placement pass seeds placements; legacy agents keep their monolithic config until their first placed-share compile
- [ ] 7.3 Verify on a scratch deployment that every device previously polled is placed or reported uncovered, and that the duplicate polls stop

## 8. Verification
- [ ] 8.1 Property tests for placement: determinism, stickiness on join, bounded movement on leave, ceiling never exceeded, redundancy distinctness
- [ ] 8.2 Handover tests: make-before-break overlap at most one interval plus grace; stale-generation acknowledgement ignored
- [ ] 8.3 Delivery tests: delta, snapshot after compaction, interrupted stream applies nothing, mixed-version partition
- [ ] 8.4 Scale test: synthetic 1,000,000-device inventory across synthetic agents; placement pass time, delta bytes for a one-device change, core memory
- [ ] 8.5 `make test`; Elixir quality gate; Go lint

## 9. Spec hygiene
- [ ] 9.1 `openspec validate distribute-snmp-targets-across-agents --strict`
- [ ] 9.2 Record follow-ups named in design.md as issues
- [ ] 9.3 At archive, reconcile `fix-default-snmp-profile-preview`'s "Seeded default SNMP profile targets all devices" wording (it cites the per-agent limit refusals this change retires)
