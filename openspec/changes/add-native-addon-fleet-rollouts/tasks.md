# Tasks: Native add-on fleet rollout policies

## 1. Data model and authorization

- [x] 1.1 Add explicit `manual_pin` and `track_latest_approved` update policies to direct add-on assignments and add-on profiles; migrate signed/verified first-party sources to tracking unless explicitly pinned and migrate other sources to `manual_pin`
- [x] 1.2 Add rollout, rollout-source, and per-agent rollout-target resources with stable/candidate package IDs, target snapshots, batch policy, prior desired state, lifecycle timestamps, evidence, and errors
- [x] 1.3 Add uniqueness/locking constraints so one active rollout owns an effective (agent, add-on) target and one candidate rollout owns a source at a time
- [x] 1.4 Apply existing add-on management authorization to policy and rollout actions and record policy/rollout transitions in audit history

## 2. Candidate eligibility and track reconciliation

- [x] 2.1 Implement deterministic latest-candidate selection by logical add-on ID, semantic version, release channel, verification/approval/revocation state, platform/agent compatibility, and capability ceiling
- [x] 2.2 Ensure package import/approval never directly mutates assignment or profile package IDs
- [x] 2.3 Reconcile managed first-party and operator-opted-in track-latest sources asynchronously into rollout candidates and queue newer approvals while a source already has an active rollout
- [ ] 2.4 Block failed or privilege-expanding candidates per source until an authorized operator explicitly retries or changes policy

## 3. Rollout coordination

- [x] 3.1 Snapshot source provenance and eligible/incompatible/overridden/unavailable/unresolved targets before rollout start
- [x] 3.2 Apply per-target rollout desired-state overrides without mutating stable profile/direct-assignment package selection
- [x] 3.3 Advance targets through canary and bounded batches with persisted pause, resume, cancel, and deadline semantics
- [x] 3.4 Promote the candidate into each authoritative source only after its required target snapshot passes; preserve dynamic-profile behavior for agents joining after promotion
- [x] 3.5 Keep profile reconciliation from deleting or overwriting active rollout overrides and preserve direct-assignment precedence

## 4. Health gates and rollback

- [x] 4.1 Extend normalized add-on status/readiness evidence where needed for continuous services, systemd timers, ephemeral helpers, and config toggles
- [x] 4.2 Require post-advance, fresh candidate-version evidence for gate evaluation and enforce configured soak, timeout, and failure tolerance
- [x] 4.3 Roll a failed target back to its prior package and params, verify recovery from fresh evidence, and pause before advancing another batch
- [x] 4.4 Add whole-rollout rollback and prevent a failed track candidate from immediately retriggering
- [x] 4.5 Emit rollout transition metrics and health events with rollout/source/target IDs and stable reason codes

## 5. Truthful fleet health semantics

- [x] 5.1 Enrich the fleet read model with agent availability, observation freshness, management origin, supervision model, expected activity, rollout state, and evidence timestamps
- [x] 5.2 Implement mutually exclusive `healthy`, `updating`, `action_required`, `unavailable`, `expected_inactive`, and `observed_only` categories with stable reason codes
- [x] 5.3 Exclude stale/offline evidence, healthy observed-only built-ins, dormant ephemeral helpers, and in-grace rollout targets from `needs_attention`
- [x] 5.3a Treat disabled assignments as audit history rather than current desired state and compare approved/runtime versions semantically before labeling an upgrade newer
- [x] 5.4 Keep explicit unhealthy observed-only runtimes and incompatible/invalid desired assignments actionable
- [x] 5.5 Expose category/reason/freshness fields through supported API and SRQL surfaces

## 6. Operator UI

- [x] 6.1 Add update-policy controls to direct assignment and add-on profile forms, showing managed tracking by default for signed/verified first-party packages and manual pin for other origins
- [ ] 6.2 Add an approved-package bulk upgrade preview grouped by authoritative source with eligible, incompatible, overridden, unavailable, ephemeral, and already-current counts
- [x] 6.3 Add canary, batch size, soak, timeout, and failure-tolerance controls and create a rollout instead of bulk-updating assignments
- [ ] 6.4 Add rollout progress/detail with per-target evidence, pause/resume/cancel, retry, and rollback actions
- [x] 6.5 Replace the single fleet summary with managed, healthy/running, updating, needs-attention, unavailable/stale, expected-inactive, and observed-only counters/filters
- [x] 6.5a Group fleet rows into one card per agent with add-on rows and aggregate alert counts
- [ ] 6.6 Show stable reason text and evidence age on every non-healthy row and show track-latest rollout impact during package approval

## 7. Verification

- [ ] 7.1 Unit-test eligibility, capability ceilings, semantic-version/channel selection, locking, target snapshots, batching, source promotion, and candidate blocking
- [ ] 7.2 State-machine-test success, pause/resume/cancel, offline timeout, per-target rollback, whole-rollout rollback, and recovery for every supervision model
- [ ] 7.3 Test profile reconciliation during canary, paused, failed, rolled-back, and completed rollouts, including direct overrides and dynamic membership
- [x] 7.4 Test fleet classification for real runtime failure, stale disconnected agent, never-reported assignment, healthy built-in observed-only runtime, dormant ephemeral helper, incompatible target, and in-progress convergence
- [x] 7.4a Persist failed profile reconciliation summaries independently of desired-state package validation
- [x] 7.4b Cover disabled-only assignment history, approved-version downgrade labeling, and non-explicit staged-profile recovery
- [x] 7.4c Cover release-envelope catalog reuse, grouped agent cards, and decimal JSON Schema controls
- [ ] 7.5 Add LiveView and Playwright coverage for bulk preview, policy controls, rollout operations, counters/filters, reason visibility, authorization, and responsive layout
- [ ] 7.6 Run mixed-version demo rollouts against at least one continuous service, one systemd timer, and one ephemeral helper; verify first-party managed sources auto-roll and explicit/non-first-party pins do not

## 8. Documentation and rollout

- [x] 8.1 Document the import -> approve -> assign/track -> automatic delivery lifecycle and make the approval-versus-deployment boundary explicit
- [x] 8.2 Document manual pin, track-latest, canary/batch, health-gate, pause, rollback, and stale/unavailable troubleshooting workflows
- [ ] 8.3 Roll out read-only categorized health first, manual rollout second, and track-latest last; publish before/after demo fleet counts with reason breakdowns
