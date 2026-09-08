# Tasks: Config-driven mitigation authority, northbound action descriptors, and the online correction loop

Phase-3 (online response) milestone of the causal security engine. Capabilities:
`causal-mitigation-authority`, `causal-mitigation-actions`, `causal-online-correction`.
Depends on `add-causal-security-detections` (SecVerdict stream, CSM trigger, counterfactual
blast radius) and extends the `add-causal-engine` chassis. DDL is authored as Elixir/Ash
migrations in the `platform` schema; ingestion never runs DDL.

## 1. Policy + decision tables (Ash migrations + resources) (capability: causal-mitigation-authority)

- [ ] 1.1 Author the Elixir/Ash migration for `platform.causal_mitigation_policies` (priority-ordered; predicate columns `min_stage`/`max_stage`/`min_confidence`/`min_severity`/`blast_radius_max`/`asset_criticality text[]`/`attck_in text[]`/`domain_in text[]`/`entity_tag_match jsonb`; `authority` CHECK in `{auto_fire,require_approval,alert_only,suppress}`; `mode` CHECK in `{shadow,enforce}`; `action_type`/`action_params jsonb`; guardrails `approver_role`/`max_fires_per_window`/`window_seconds`/`cooldown_seconds`/`expires_at`; `enabled boolean DEFAULT true`).
- [ ] 1.2 Author the Ash resource for the policy table (modeled on `observability/stateful_alert_rule.ex`; `platform` schema; system-actor authorization; paper-trail versions; `enabled`/`priority`/`mode` change actions).
- [ ] 1.3 Author the Elixir/Ash migration for the append-only `platform.mitigation_decisions` (`verdict_ref`, `entity`, `stage`, `confidence`, `blast_radius`, `matched_policy_id`, `authority`, `action_type`, `mode`, `outcome` CHECK in `{fired,enqueued,alerted,suppressed,would_fire,failed}`, `approver`, `decided_at`; hypertable candidate; append-only — no update/delete action).
- [ ] 1.4 Author the Ash resource for `mitigation_decisions` (create-and-read only; index on `(entity, decided_at)` and `matched_policy_id`).
- [ ] 1.5 Seed a set of representative `mode='shadow'` starter policies (default-deny remains the fallback when none match under `enforce`).

## 2. Policy engine — predicate match, default-deny, shadow/enforce (capability: causal-mitigation-authority)

- [ ] 2.1 Create `rust/causal-mitigation` (root-workspace member, mirrors `rust/anomaly-*`; package `serviceradar-causal-mitigation`; depends on `causal-model`, `causal-ports`; `BUILD.bazel` with `all_crate_deps`).
- [ ] 2.2 Define the `MitigationPolicy` port surface in `rust/causal-ports` (load enabled rules ordered by priority; supply the current guardrail counters) and the `ActionExecutor`/decision-sink port (append a `mitigation_decisions` row; dispatch a northbound action).
- [ ] 2.3 Implement pure predicate matching: AND-ed columns with `NULL`=wildcard, first enabled match by `priority`; a verdict matching no enabled `enforce` rule resolves to `alert_only` (default-deny). Unit-test wildcard, priority ordering, and the default-deny fallback.
- [ ] 2.4 Implement mode handling: `shadow` `auto_fire` produces a decision with `outcome='would_fire'` and NO actuation; `enforce` `auto_fire` proceeds to actuation. `require_approval`/`alert_only`/`suppress` behave identically in shadow and enforce except for audit `outcome`.
- [ ] 2.5 Wire the decision path so every one of the four authority outcomes appends exactly one `mitigation_decisions` row via the decision-sink port. Unit-test one row per decision.
- [ ] 2.6 Implement guardrail enforcement (`max_fires_per_window`/`window_seconds`, `cooldown_seconds`, `expires_at`) as preconditions on `auto_fire` actuation.

## 3. Blast-radius safety gate (capability: causal-mitigation-authority)

- [ ] 3.1 Consume the counterfactual blast-radius value from `add-causal-security-detections` / the `add-causal-engine` counterfactual, computed BEFORE `policy.decide` is invoked, and thread it into the decision as `blast_radius`.
- [ ] 3.2 Gate `auto_fire` on `blast_radius <= blast_radius_max`; when it exceeds, downgrade the resolved authority to `require_approval` and record the downgrade in `authority`/`outcome`. Unit-test the `blast_radius_max=3` vs predicted-10 downgrade.
- [ ] 3.3 Record `blast_radius` on every decision row (not only downgraded ones) for auditability.

## 4. Northbound action descriptors + provider (capability: causal-mitigation-actions)

- [ ] 4.1 Author `ActionDescriptor` records for `block-flow`, `revoke-session`, and `quarantine` (`input_schema`, `safety_classification`, `requires_confirmation`, `scopes`, `credential_requirements`, `result_schema_version`) via the existing `automation/northbound/action_descriptor.ex` upsert path (`platform.northbound_action_descriptors`).
- [ ] 4.2 Register one `ActionProvider` (`automation/northbound/action_provider.ex`; `platform.northbound_action_providers`) that advertises `approved_capabilities` covering the three action_ids and transitions to `active`.
- [ ] 4.3 Implement the provider so the existing `Dispatcher` (`automation/northbound/dispatcher.ex`) can invoke `block-flow` (and the others) end-to-end through the standard invocation/audit/callback path.
- [ ] 4.4 Map the policy `action_type`/`action_params` to a `(provider_id, action_id, version)` descriptor + invocation input for `enforce` `auto_fire`.
- [ ] 4.5 Test: an `enforce`-mode `auto_fire` decision dispatches a `block-flow` action through the new provider and records `outcome='fired'`.

## 5. Policy-dispatch wiring into the CSM (capability: causal-mitigation-authority, causal-mitigation-actions)

- [ ] 5.1 Have the CSM `CausalAction` fire (authored by `add-causal-security-detections`) invoke the `rust/causal-mitigation` policy engine as its action, passing the pending `SecVerdict` and the pre-computed blast radius.
- [ ] 5.2 Route the resolved authority: `auto_fire` → northbound dispatch (enforce) or `would_fire` (shadow); `require_approval` → enqueue + notify approver role; `alert_only` → raise alert only; `suppress` → drop. All append to `mitigation_decisions`.

## 6. Online detect→mitigate correction loop (capability: causal-online-correction)

- [ ] 6.1 Implement the tick loop in `rust/causal-reasoning` using `CausalFlow::from(initial).iterate_n(N, ...)` with `bind(analyze_tick)` and `branch_with(hot?, latch, cold)`; `SlidingWindow` z-score in State.
- [ ] 6.2 Baseline-withholding: `if !anomalous { window.push(sample) }` — anomalous samples never enter the baseline (anti-poisoning). Unit-test a slow-ramp series that stays anomalous rather than re-baselining.
- [ ] 6.3 Consecutive-slots debounce: latch only when `consecutive_anomalies >= trigger_slots`; a single spike does not respond. Unit-test single-spike no-op.
- [ ] 6.4 Latch-once + operator-gated release: mitigation latches once; stand-down is confirmed on the RAW offered load (not the withheld baseline) and requires operator gating. Unit-test that abatement on raw load is required before release.
- [ ] 6.5 Gate the loop behind config; keep `expected_value`/`standard_deviation` (fixed 1000-sample) off the hot path and clear the DC process-global sample cache per tick.

## 7. Validation

- [ ] 7.1 `cargo build` / `cargo clippy --all-targets -D warnings` / `cargo fmt --check` for `rust/causal-mitigation` + `rust/causal-reasoning`; `bazel build` the new crate targets.
- [ ] 7.2 Ash migration up/down + resource tests for the two tables (default-deny fallback, append-only decisions, `would_fire` shadow path).
- [ ] 7.3 End-to-end: shadow `auto_fire` logs `would_fire` and does nothing; promote to `enforce`, verify block-flow dispatch and the blast-radius downgrade.
- [ ] 7.4 `openspec validate add-causal-mitigation --strict` passes.
