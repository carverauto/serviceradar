# causal-mitigation-authority Specification (delta for add-causal-mitigation)

This delta adds the runtime authority layer that decides, per `SecVerdict`, whether a
mitigation may auto-fire, must wait for a human, should only alert, or should be
suppressed — plus the append-only audit that makes shadow-first promotion possible and the
blast-radius safety gate. It consumes the `SecVerdict` stream and counterfactual blast
radius from `add-causal-security-detections` and is authored on the `add-causal-engine`
chassis. DDL is authored as Elixir/Ash migrations in the `platform` schema; ingestion never
runs DDL.

## ADDED Requirements

### Requirement: Mitigation Authority Policy Table

Mitigation authority SHALL be governed by a runtime, priority-ordered policy table
`platform.causal_mitigation_policies`, authored via an Elixir/Ash migration and Ash resource
in the `platform` schema (modeled on `stateful_alert_rules`), NOT hardcoded in engine code.
Each rule SHALL expose AND-ed predicate columns — at minimum `min_stage`, `max_stage`,
`min_confidence`, `min_severity`, `blast_radius_max`, `asset_criticality`, `attck_in`,
`domain_in`, and `entity_tag_match` — where a `NULL` predicate column matches any verdict.
Each rule SHALL resolve to an `authority` in `{auto_fire, require_approval, alert_only,
suppress}`, SHALL carry a `mode` in `{shadow, enforce}`, and SHALL carry guardrail columns
(`approver_role`, `max_fires_per_window`, `window_seconds`, `cooldown_seconds`, `expires_at`).
The engine SHALL evaluate enabled rules in ascending `priority` order and take the first
match. Authority SHALL be **default-deny**: a verdict matching no enabled rule in `enforce`
mode SHALL resolve to `alert_only` and SHALL NOT auto-fire.

#### Scenario: Verdict matching no enabled enforce rule is alert_only

- **GIVEN** a `SecVerdict` for an entity
- **AND** no enabled `enforce`-mode rule in `platform.causal_mitigation_policies` matches the verdict's predicates
- **WHEN** the policy engine resolves authority
- **THEN** the resolved authority SHALL be `alert_only`
- **AND** the verdict SHALL NOT auto-fire any mitigation

#### Scenario: First enabled rule by priority wins with wildcard predicates

- **GIVEN** two enabled rules whose predicate columns both match a verdict, with `NULL` columns treated as wildcards
- **WHEN** the policy engine evaluates rules in ascending `priority` order
- **THEN** the authority from the lower-`priority` (first-matching) rule SHALL be applied
- **AND** the later rule SHALL NOT override it

#### Scenario: Authority is a runtime table, not hardcoded

- **WHEN** an operator changes a rule's `authority`, `mode`, or predicate columns in `platform.causal_mitigation_policies`
- **THEN** the policy engine SHALL apply the updated rule to subsequent verdicts without an engine rebuild or redeploy

### Requirement: Shadow-First Promotion and Decision Audit

Every authority decision SHALL append exactly one row to an append-only decision-audit table
`platform.mitigation_decisions` recording at least `verdict_ref`, `entity`, `stage`,
`confidence`, `blast_radius`, `matched_policy_id`, `authority`, `action_type`, `mode`,
`outcome`, `approver`, and `decided_at`, where `outcome` is one of `fired`, `enqueued`,
`alerted`, `suppressed`, `would_fire`, or `failed`. The table SHALL be append-only (no update
or delete of decided rows). In `shadow` mode an `auto_fire` match SHALL write
`outcome='would_fire'` and SHALL take no other action (no northbound dispatch, no approval
enqueue), so that operators can review what a rule *would* do and promote it to `enforce`
after review.

#### Scenario: A shadow rule logs would_fire without acting

- **GIVEN** an enabled rule with `authority='auto_fire'` and `mode='shadow'` that matches a verdict
- **WHEN** the policy engine decides on the verdict
- **THEN** it SHALL append a `mitigation_decisions` row with `outcome='would_fire'`
- **AND** it SHALL NOT dispatch any northbound action, enqueue any approval, or otherwise actuate

#### Scenario: Every authority outcome is audited exactly once

- **WHEN** the policy engine resolves any authority (`auto_fire`, `require_approval`, `alert_only`, or `suppress`) for a verdict
- **THEN** it SHALL append exactly one row to `platform.mitigation_decisions`
- **AND** that row SHALL NOT be updated or deleted after it is written

#### Scenario: Promotion from shadow to enforce

- **GIVEN** a rule in `mode='shadow'` that has accumulated `would_fire` decision rows
- **WHEN** an operator flips the rule to `mode='enforce'`
- **THEN** subsequent matching `auto_fire` decisions SHALL actuate and record an actuation outcome (`fired` or `failed`) rather than `would_fire`

### Requirement: Blast-Radius Safety Gate

`auto_fire` SHALL be gated by the rule's `blast_radius_max` evaluated against the
counterfactual blast radius computed **before** the policy is consulted (the `do(compromise =
entity)` forward simulation from `add-causal-security-detections` / the `add-causal-engine`
counterfactual). When the predicted blast radius exceeds `blast_radius_max`, the resolved
authority SHALL downgrade from `auto_fire` to `require_approval`, and the downgrade SHALL be
reflected in the recorded `authority` and `outcome`. The evaluated `blast_radius` SHALL be
recorded on every decision row, not only downgraded ones. A `NULL` `blast_radius_max` SHALL
impose no blast constraint on that rule.

#### Scenario: Auto-isolate downgrades when predicted blast exceeds the cap

- **GIVEN** an enabled `enforce`-mode rule with `authority='auto_fire'` and `blast_radius_max=3`
- **AND** the counterfactual blast radius computed before the policy is consulted is 10 hosts
- **WHEN** the policy engine decides on the matching verdict
- **THEN** the resolved authority SHALL downgrade to `require_approval`
- **AND** the decision SHALL NOT auto-fire the isolation action
- **AND** the recorded decision SHALL carry `blast_radius=10` and the downgraded authority

#### Scenario: Blast radius is computed before the policy is consulted

- **WHEN** a verdict reaches the mitigation authority path
- **THEN** the counterfactual blast radius SHALL be computed first and passed into the policy decision
- **AND** the recorded decision row SHALL include the evaluated `blast_radius` value

#### Scenario: Within-cap auto_fire is not downgraded by the gate

- **GIVEN** an enabled `enforce`-mode `auto_fire` rule with `blast_radius_max=3`
- **AND** the counterfactual blast radius is 2 hosts
- **WHEN** the policy engine decides on the matching verdict
- **THEN** the blast-radius gate SHALL NOT downgrade the authority
- **AND** the authority SHALL remain `auto_fire` (subject to guardrails)
