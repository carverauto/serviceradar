# Tasks: Native add-on fleet rollout policies

## 1. Data model and authorization

- [ ] 1.1 Add explicit `manual_pin` and `track_latest_approved` update policies to direct add-on assignments and add-on profiles; migrate every existing source to `manual_pin`
- [ ] 1.2 Add rollout, rollout-source, and per-agent rollout-target resources with stable/candidate package IDs, target snapshots, batch policy, prior desired state, lifecycle timestamps, evidence, and errors
- [ ] 1.3 Add uniqueness/locking constraints so one active rollout owns an effective (agent, add-on) target and one candidate rollout owns a source at a time
- [ ] 1.4 Apply existing add-on management authorization to policy and rollout actions and record policy/rollout transitions in audit history

## 2. Candidate eligibility and track reconciliation

- [ ] 2.1 Implement deterministic latest-candidate selection by logical add-on ID, semantic version, release channel, verification/approval/revocation state, platform/agent compatibility, and capability ceiling
- [ ] 2.2 Ensure package import/approval never directly mutates assignment or profile package IDs
- [ ] 2.3 Reconcile opted-in track-latest sources asynchronously into rollout candidates and queue newer approvals while a source already has an active rollout
- [ ] 2.4 Block failed or privilege-expanding candidates per source until an authorized operator explicitly retries or changes policy

## 3. Rollout coordination

- [ ] 3.1 Snapshot source provenance and eligible/incompatible/overridden/unavailable/unresolved targets before rollout start
- [ ] 3.2 Apply per-target rollout desired-state overrides without mutating stable profile/direct-assignment package selection
- [ ] 3.3 Advance targets through canary and bounded batches with persisted pause, resume, cancel, and deadline semantics
- [ ] 3.4 Promote the candidate into each authoritative source only after its required target snapshot passes; preserve dynamic-profile behavior for agents joining after promotion
- [ ] 3.5 Keep profile reconciliation from deleting or overwriting active rollout overrides and preserve direct-assignment precedence

## 4. Health gates and rollback

- [ ] 4.1 Extend normalized add-on status/readiness evidence where needed for continuous services, systemd timers, ephemeral helpers, and config toggles
- [ ] 4.2 Require post-advance, fresh candidate-version evidence for gate evaluation and enforce configured soak, timeout, and failure tolerance
- [ ] 4.3 Roll a failed target back to its prior package and params, verify recovery from fresh evidence, and pause before advancing another batch
- [ ] 4.4 Add whole-rollout rollback and prevent a failed track candidate from immediately retriggering
- [ ] 4.5 Emit rollout transition metrics and health events with rollout/source/target IDs and stable reason codes

## 5. Truthful fleet health semantics

- [ ] 5.1 Enrich the fleet read model with agent availability, observation freshness, management origin, supervision model, expected activity, rollout state, and evidence timestamps
- [ ] 5.2 Implement mutually exclusive `healthy`, `updating`, `action_required`, `unavailable`, `expected_inactive`, and `observed_only` categories with stable reason codes
- [ ] 5.3 Exclude stale/offline evidence, healthy observed-only built-ins, dormant ephemeral helpers, and in-grace rollout targets from `needs_attention`
- [ ] 5.4 Keep explicit unhealthy observed-only runtimes and incompatible/invalid desired assignments actionable
- [ ] 5.5 Expose category/reason/freshness fields through supported API and SRQL surfaces

## 6. Operator UI

- [ ] 6.1 Add update-policy controls to direct assignment and add-on profile forms, with manual pin as the visible default
- [ ] 6.2 Add an approved-package bulk upgrade preview grouped by authoritative source with eligible, incompatible, overridden, unavailable, ephemeral, and already-current counts
- [ ] 6.3 Add canary, batch size, soak, timeout, and failure-tolerance controls and create a rollout instead of bulk-updating assignments
- [ ] 6.4 Add rollout progress/detail with per-target evidence, pause/resume/cancel, retry, and rollback actions
- [ ] 6.5 Replace the single fleet summary with managed, healthy/running, updating, needs-attention, unavailable/stale, expected-inactive, and observed-only counters/filters
- [ ] 6.6 Show stable reason text and evidence age on every non-healthy row and show track-latest rollout impact during package approval

## 7. Verification

- [ ] 7.1 Unit-test eligibility, capability ceilings, semantic-version/channel selection, locking, target snapshots, batching, source promotion, and candidate blocking
- [ ] 7.2 State-machine-test success, pause/resume/cancel, offline timeout, per-target rollback, whole-rollout rollback, and recovery for every supervision model
- [ ] 7.3 Test profile reconciliation during canary, paused, failed, rolled-back, and completed rollouts, including direct overrides and dynamic membership
- [ ] 7.4 Test fleet classification for real runtime failure, stale disconnected agent, never-reported assignment, healthy built-in observed-only runtime, dormant ephemeral helper, incompatible target, and in-progress convergence
- [ ] 7.5 Add LiveView and Playwright coverage for bulk preview, policy controls, rollout operations, counters/filters, reason visibility, authorization, and responsive layout
- [ ] 7.6 Run mixed-version demo rollouts against at least one continuous service, one systemd timer, and one ephemeral helper; verify no automatic updates occur before opt-in

## 8. Documentation and rollout

- [ ] 8.1 Document the import -> approve -> assign/track -> automatic delivery lifecycle and make the approval-versus-deployment boundary explicit
- [ ] 8.2 Document manual pin, track-latest, canary/batch, health-gate, pause, rollback, and stale/unavailable troubleshooting workflows
- [ ] 8.3 Roll out read-only categorized health first, manual rollout second, and track-latest last; publish before/after demo fleet counts with reason breakdowns
