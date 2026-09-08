# Change: Config-driven mitigation authority, northbound action descriptors, and the online correction loop

## Why

The causal security engine can now detect cross-domain incidents (`add-causal-security-detections`), but *acting* on them is undecided and unbuildable: which verdicts may auto-fire versus wait for a human is hardcoded nowhere, and the `northbound_action_*` framework ships as a generic provider-neutral dispatch/audit shell with **no** block-flow, revoke-session, or quarantine actions to dispatch. This change closes the Phase-3 response gap — a runtime, shadow-first authority policy table plus the missing northbound action descriptors and provider — and adds the online detect→mitigate correction loop with the anti-poisoning discipline the `ddos_detector` template teaches.

## What Changes

- **Mitigation authority policy table (`platform.causal_mitigation_policies`).** A runtime, priority-ordered, default-deny policy table (modeled on `stateful_alert_rules`) whose AND-ed predicate columns (`min_stage`/`max_stage`/`min_confidence`/`min_severity`/`blast_radius_max`/`asset_criticality`/`attck_in`/`domain_in`/`entity_tag_match`) resolve a verdict to an authority in `{auto_fire, require_approval, alert_only, suppress}`. Each rule carries a `mode` of `shadow | enforce`, guardrails (`approver_role`, `max_fires_per_window`, `window_seconds`, `cooldown_seconds`, `expires_at`), and Phase-3 `action_type`/`action_params`. Authored via an Elixir/Ash migration in the `platform` schema and a matching Ash resource; ingestion never runs DDL.
- **Shadow-first promotion + append-only decision audit (`platform.mitigation_decisions`).** Every authority decision appends one row (`verdict_ref`, `entity`, `stage`, `confidence`, `blast_radius`, `matched_policy_id`, `authority`, `action_type`, `mode`, `outcome`, `approver`, `decided_at`). A `shadow`-mode `auto_fire` rule writes `outcome='would_fire'` and does nothing else, so operators promote rules to `enforce` only after reviewing what they *would* have done. Default-deny: a verdict matching no enabled `enforce` rule is `alert_only`.
- **Blast-radius safety gate.** `auto_fire` is gated by `blast_radius_max` evaluated against the counterfactual blast radius (from `add-causal-security-detections` / the `add-causal-engine` counterfactual) computed **before** the policy is consulted; when the predicted blast exceeds the gate the authority downgrades to `require_approval`.
- **Northbound action descriptors + registered provider (gap #4).** Because `northbound_action_*` has no block-flow/revoke-session/quarantine actions today, this change authors those `ActionDescriptor` records and a registered `ActionProvider` implementation, so an `enforce`-mode `auto_fire` can actually dispatch a `block-flow` action through the existing `Dispatcher` / audit path.
- **Online detect→mitigate correction loop.** A reasoning-side tick loop (`iterate_n` + `branch_with` + `alternate_value`) with (a) **baseline-withholding** so anomalous samples never enter the baseline (anti-poisoning / defeats the slow-ramp "boil-the-frog" attack), (b) a **consecutive-slots debounce** so a single noisy spike does not respond, and (c) **latch-once** mitigation with operator-gated release confirmed on the **raw** offered load before stand-down.
- **Policy-dispatch wiring.** The CSM `fire()` path (from `add-causal-security-detections`) invokes the policy engine as its action, which returns the authority tier and, on `enforce` `auto_fire`, hands the action descriptor + params to the northbound dispatcher; all four outcomes append to `mitigation_decisions`.

This change adds new tables and a new response surface but does **not** break existing behavior; all rules default to `shadow` and default-deny, so no verdict auto-fires until an operator authors and promotes an `enforce` rule.

## Impact

- **Affected specs (capabilities):** ADDED `causal-mitigation-authority`, `causal-mitigation-actions`, `causal-online-correction`.
- **Affected code:**
  - NEW Elixir/Ash migrations + resources for `platform.causal_mitigation_policies` and `platform.mitigation_decisions` (in `elixir/serviceradar_core`, `platform` schema; modeled on `observability/stateful_alert_rule.ex`).
  - NEW `northbound_action_descriptors` rows (block-flow / revoke-session / quarantine) + a registered `northbound_action_providers` entry and its provider implementation, extending `automation/northbound/action_descriptor.ex`, `action_provider.ex`, and `dispatcher.ex` (no framework redesign).
  - Rust `rust/causal-mitigation` — the pure policy-decision engine (predicate match, default-deny, shadow/enforce, blast-radius gate) behind the `MitigationPolicy` / `ActionExecutor` ports (`rust/causal-ports`); policy rows and the decision/audit sink are supplied through ports implemented in `rust/causal-ingest` / `rust/causal-emit` (only those touch CNPG/NATS).
  - Rust `rust/causal-reasoning` — the correction-loop tick (`CausalFlow::iterate_n` / `branch_with` / `alternate_value`, `SlidingWindow` in State) with baseline-withholding, debounce, and latch-once release.
  - The CSM action seam authored by `add-causal-security-detections` invokes the policy engine as its `CausalAction`.
- **Dependencies / Coordinate:**
  - **Depends on `add-causal-security-detections`** for the `SecVerdict` stream, the CSM detect→respond trigger it wires the policy dispatch into, and the counterfactual blast-radius computation the safety gate consumes.
  - **Extends `add-causal-engine`** (the settled chassis: `rust/causal-engine`, the three ingestion feeds, `signals.analytics.predictions.>` emission via `AnalyticsSignals`, `god_view_nif` demotion, reliability causaloids C1–C13). Inherits its infrastructure decisions; does not redefine the chassis.
  - **Builds on `add-causal-security-foundation`** for the shared `SecVerdict` / `Stage` / `EvidenceRef` vocabulary and the `rust/causal-*` crate layout.
  - **Richer blast radius from `add-identity-asset-flow-bridge`.** V1 blast radius is network-tier reachability (AGE `platform_graph`); the identity↔asset↔flow bridge sharpens the counterfactual the gate reads. Coordinate the `blast_radius` semantics with that change.
  - **Feeds `add-causal-detection-feedback`.** The `mitigation_decisions` audit trail and `would_fire` shadow outcomes are inputs to the analyst TP/FP labeling + calibration surface authored there.
