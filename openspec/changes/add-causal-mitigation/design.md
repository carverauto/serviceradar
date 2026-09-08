# Design — add-causal-mitigation

## Context

This change is Milestone 4 (Phase 3, online response) of the causal *security* engine
program described in `openspec/notes/sr-causal-engine.md` (§4.7a, §4.7, §7 gap #4,
§9 Phase 3, §10 Q3). It extends the settled chassis change `add-causal-engine` and
depends on `add-causal-security-detections`, which produces the `SecVerdict` stream and
the CSM detect→respond trigger.

Two verified constraints shape every decision here:

- **Authority is undecided, not just unbuilt.** Whether a verdict may auto-fire or must
  wait for a human is hardcoded nowhere. §4.7a / §10 Q3 resolve this as a *runtime config
  table* modeled on `stateful_alert_rules` (`observability/stateful_alert_rule.ex`), authored
  shadow-first and default-deny.
- **The actions do not exist.** The `northbound_action_*` framework
  (`automation/northbound/action_descriptor.ex`, `action_provider.ex`, `dispatcher.ex`;
  tables `platform.northbound_action_descriptors` / `northbound_action_providers`) is a
  generic, provider-neutral dispatch/audit shell. It has **no** block-flow / revoke-session /
  quarantine action descriptors and **no** provider that implements them (§4.5, §7 gap #4).
  So closing the *authority* decision does not close the *actuation* gap; both are in scope.

Crate placement follows §8.1: the pure decision logic lives in `rust/causal-mitigation`
(depends on `causal-model`, `causal-ports`); policy rows and the audit/actuation sink cross
the process boundary through `MitigationPolicy` / `ActionExecutor` ports in `rust/causal-ports`
whose implementations live in `rust/causal-ingest` / `rust/causal-emit` (the only crates that
touch CNPG/NATS). The correction-loop tick lives in `rust/causal-reasoning` (the generic
engine crate that owns graph eval, CSM, correction, and counterfactual). DDL is authored as
Elixir/Ash migrations in the `platform` schema; ingestion never runs DDL.

## Goals / Non-Goals

Goals:

- A runtime, priority-ordered, **default-deny** authority policy table
  `platform.causal_mitigation_policies` with AND-ed predicate columns, a `shadow | enforce`
  mode per rule, and guardrails — authored via Ash migration + resource.
- An **append-only** decision audit `platform.mitigation_decisions` where a `shadow`
  `auto_fire` writes `outcome='would_fire'` and takes no action, enabling shadow-first promotion.
- A **blast-radius safety gate**: `auto_fire` is contingent on the counterfactual blast radius
  (computed before the policy is consulted) staying within `blast_radius_max`, else it downgrades.
- The missing **northbound action descriptors** (block-flow, revoke-session, quarantine) and a
  **registered provider** that implements them, so an `enforce` `auto_fire` actually dispatches.
- The **online detect→mitigate correction loop** with baseline-withholding, consecutive-slots
  debounce, and latch-once + operator-gated release confirmed on raw offered load.

Non-Goals:

- **Re-deciding the detection stack.** `SecVerdict`, `Stage`, `EvidenceRef`, the CSM trigger,
  and the counterfactual blast-radius engine are owned by `add-causal-security-detections` and
  `add-causal-engine`; this change consumes them.
- **Redesigning the northbound framework.** We add descriptors + a provider inside the existing
  `ActionDescriptor` / `ActionProvider` / `Dispatcher` contracts; we do not change the framework.
- **Host-auth ingest / identity blast radius.** V1 blast radius is network-tier reachability
  (AGE `platform_graph`); identity-level blast radius is `add-identity-asset-flow-bridge`.
- **The analyst TP/FP labeling + variance calibration surface** (`add-causal-detection-feedback`).
  This change only *emits* the `mitigation_decisions` / `would_fire` trail it will consume.

## Decisions

### Decision 1 — Authority is a runtime table, shadow-first, default-deny

Model `platform.causal_mitigation_policies` on `stateful_alert_rules`: `priority integer`,
`enabled boolean`, `mode text CHECK (mode IN ('shadow','enforce'))`, AND-ed predicate columns
(`min_stage`, `max_stage`, `min_confidence`, `min_severity`, `blast_radius_max`,
`asset_criticality text[]`, `attck_in text[]`, `domain_in text[]`, `entity_tag_match jsonb`;
`NULL` = wildcard), `authority text CHECK (authority IN ('auto_fire','require_approval','alert_only','suppress'))`,
Phase-3 `action_type`/`action_params jsonb`, and guardrails (`approver_role`,
`max_fires_per_window`, `window_seconds`, `cooldown_seconds`, `expires_at`). The engine
evaluates rules in `priority` order and takes the first **enabled** match; a verdict matching no
enabled `enforce` rule resolves to `alert_only` (default-deny — no silent auto-fire).

Alternatives considered:

- **Hardcode authority in the causaloid catalog.** Rejected: couples response policy to a
  Rust release, and operators cannot tune blast tolerance or approver routing without a rebuild.
- **Reuse `stateful_alert_rules` directly.** Rejected: that table models alert grouping/threshold
  state, not response authority + guardrails + blast gating; overloading it entangles two lifecycles.

### Decision 2 — Every decision is audited; shadow `auto_fire` writes `would_fire` only

`platform.mitigation_decisions` is append-only (hypertable candidate): `verdict_ref`, `entity`,
`stage`, `confidence`, `blast_radius`, `matched_policy_id`, `authority`, `action_type`, `mode`,
`outcome ('fired'|'enqueued'|'alerted'|'suppressed'|'would_fire'|'failed')`, `approver`,
`decided_at`. In `shadow` mode an `auto_fire` match writes `outcome='would_fire'` and performs no
action — the promotion evidence. Operators review `would_fire` rows, then flip the rule to
`enforce`. All four authority outcomes append exactly one row, so the audit is complete whether or
not anything was actuated.

Alternatives considered:

- **Log only enforced/fired decisions.** Rejected: shadow-first promotion is impossible without
  recording what a shadow rule *would* have done.
- **Mutable decision rows updated in place.** Rejected: an append-only trail is the audit
  guarantee and the clean input to `add-causal-detection-feedback` calibration.

### Decision 3 — Blast-radius gate is evaluated before the policy, against the counterfactual

The counterfactual blast radius (`do(compromise = entity)` run forward over the network-tier
reachability graph, §4.6) is computed **before** `policy.decide` is called and passed in. A rule's
`blast_radius_max` is a hard precondition on `auto_fire`: when the predicted blast exceeds it the
authority downgrades to `require_approval` (never silently fires wide). This keeps the safety
property independent of predicate matching — a rule can match on stage/confidence yet still be
denied auto-fire because the counterfactual says the action would touch too many hosts.

Alternatives considered:

- **Gate after selecting authority, inside actuation.** Rejected: the downgrade must be visible in
  the recorded `authority`/`outcome`, and the blast value must be auditable per decision.
- **Static per-action blast caps.** Rejected: blast radius is entity- and topology-dependent; a
  static cap cannot express "isolate this leaf, escalate that hub."

### Decision 4 — Author the missing northbound descriptors + a registered provider

Add `ActionDescriptor` rows for `block-flow`, `revoke-session`, and `quarantine` (each with
`input_schema`, `safety_classification`, `requires_confirmation`, `scopes`, `credential_requirements`)
and register one `ActionProvider` that implements them, reusing the existing `Dispatcher` and audit
path. `enforce` `auto_fire` maps the policy's `action_type`/`action_params` to a descriptor +
invocation. No change to the framework contracts.

Alternatives considered:

- **Emit an alert and rely on a human to run the action.** Rejected: that is `require_approval`,
  not `auto_fire`; Phase 3's deliverable is closed-loop actuation.
- **Bespoke actuation outside the northbound framework.** Rejected: duplicates dispatch, audit,
  credential-grant, and callback machinery the framework already provides.

### Decision 5 — The correction loop withholds the baseline and latches once

The online loop follows the `corrective_ddos_detector` template:
`CausalFlow::from(initial).iterate_n(N, |tick| tick.bind(analyze_tick).branch_with(hot?, latch, cold))`.
Three disciplines are load-bearing: (a) **baseline-withholding** — `if !anomalous { window.push(sample) }`
so anomalous samples never enter the `SlidingWindow`, defeating the slow-ramp "boil-the-frog"
attack that would otherwise inflate its own baseline; (b) **consecutive-slots debounce** —
mitigate only after `consecutive_anomalies >= trigger_slots`, so a single spike does not respond;
(c) **latch-once + operator-gated release** — mitigation latches once and stand-down is confirmed on
the **raw** offered load, not the (withheld) baseline.

Alternatives considered:

- **Feed every sample into the baseline.** Rejected: this is exactly the poisoning vector — a slow
  ramp trains the detector to accept the flood.
- **Auto-release on baseline recovery.** Rejected: the withheld baseline never sees the attack, so
  releasing on it would flap; release is gated on raw load and operator confirmation.

## Risks / Trade-offs

- **Auto-fire acting on a false positive.** Mitigation: default-deny + shadow-first promotion +
  the blast-radius gate + guardrails (`max_fires_per_window`, `cooldown_seconds`); nothing fires
  until an operator promotes a rule to `enforce` after reviewing `would_fire` evidence.
- **Actuation blast (isolating a hub).** Mitigation: the counterfactual blast gate downgrades wide
  actions to `require_approval`; `blast_radius` is recorded on every decision.
- **Stale/at-least-once policy or verdict state.** The policy table is small and cached; decisions
  are idempotent on `verdict_ref` + `matched_policy_id`; re-evaluation of the same verdict re-derives
  the same authority and does not double-actuate (dispatcher invocation keyed on the decision id).
- **Correction-loop tick cost.** `iterate_n` bounds the loop; keep `expected_value`/`standard_deviation`
  (fixed 1000-sample, no early-exit) off the hot path per §10 Q6; the DC sample cache is process-global
  and must be cleared per tick to avoid stale draws.

## Migration Plan

1. **Author DDL as Ash migrations.** `platform.causal_mitigation_policies` and
   `platform.mitigation_decisions` land via Elixir/Ash migrations in the `platform` schema; ship the
   matching Ash resources (system-actor authorized, paper-trail on the policy table).
2. **Seed shadow rules.** All initial rules are `mode='shadow'`; no verdict auto-fires. Operators watch
   `mitigation_decisions.outcome='would_fire'`.
3. **Author descriptors + provider.** Land the block-flow / revoke-session / quarantine descriptors and
   register the provider; `enforce` `auto_fire` remains inert until a rule is promoted.
4. **Promote per-rule.** After review, flip individual rules to `enforce`; the blast gate and guardrails
   still bound each fire. Reversible by flipping back to `shadow`.
5. **Wire the correction loop** behind a config flag, shadow-first (log `would_fire` latch decisions),
   before enabling operator-gated actuation.

## Open Questions

- **Blast-radius units across changes.** Network-tier reachability count today; when
  `add-identity-asset-flow-bridge` lands service/identity blast radius, is `blast_radius_max` compared
  against the same unit, or does the rule carry a `blast_dimension`? Coordinate before promotion.
- **Approval routing transport.** Does `require_approval` enqueue through the existing northbound
  deferred-action/approval path, or a new causal-specific approval queue? Reuse is preferred.
- **Correction-loop identity.** Is the loop per-entity or per-incident-cluster (mirrors §10 Q2)? Sets the
  number of concurrent latches and the per-tick cost budget.
- **`would_fire` retention.** How long are shadow decisions retained before they feed
  `add-causal-detection-feedback` calibration and are rolled off?
