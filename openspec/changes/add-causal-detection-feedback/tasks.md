# Tasks: Analyst label feedback + confidence calibration, and ATT&CK technique tagging

Phase 4 (feedback) of the causal security engine. Extends the `add-causal-engine` chassis; depends on
`add-causal-security-detections` (S1–S7 must exist to tag/label). All DB schema changes go through the
Ash codegen workflow in the `platform` schema — the Rust engine never runs DDL.

## 1. Analyst labeling store + migration + UI hook

- [ ] 1.1 Author an Ash resource for the analyst verdict label store in the `platform` schema
  (`causal_detection_labels`): columns for `verdict_ref` (prediction/incident id), `alert_id`/`finding_id`,
  canonical `sr:`-prefixed `entity`, `label` enum (`true_positive` | `false_positive` | `benign` |
  `unknown`), `contributing_domains text[]` (the evidence domains that drove the verdict), `stage`,
  `severity`, `attck text[]`, `notes`, `labeled_by`, `labeled_at`.
- [ ] 1.2 Generate the migration via `mix ash.codegen add_causal_detection_labels` and apply with
  `mix ash.migrate` (never `mix ecto.*`). Confirm the table lands in the `platform` schema.
- [ ] 1.3 Enforce that each label references an existing verdict/alert and captures its
  `contributing_domains` so the calibration loop can attribute the label back to per-domain confidences.
- [ ] 1.4 Add a LiveView disposition control on the alert/finding detail surface (God-View / alert
  detail) that writes a label through the Ash resource; default state is unlabeled.
- [ ] 1.5 Add Ash policies so only authorized analyst roles can write labels; append-only history (a
  re-label writes a new row / supersedes, never silently mutates).
- [ ] 1.6 Unit/integration tests: an analyst marks an alert false-positive → a label row is persisted and
  readable by the calibration query.

## 2. Confidence variance calibration mapping

- [ ] 2.1 Author an Ash resource + migration for `platform.causal_domain_calibration`: per-domain
  `variance_multiplier` (or absolute variance), `fp_count`/`tp_count` over the window, `window_seconds`,
  `floor`/`ceiling` bounds, `updated_at`.
- [ ] 2.2 Implement the recompute job (Oban): aggregate `causal_detection_labels` per `domain` over the
  window, compute a per-domain false-positive rate, and map it to a `variance_multiplier` — high FP rate
  widens the variance; confirmed TPs may tighten it toward the floor. Bound every adjustment by
  `floor`/`ceiling` so a domain is never fully suppressed nor over-trusted.
- [ ] 2.3 In `rust/causal-ingest` / `rust/causal-config`, read `platform.causal_domain_calibration` at
  hydrate/refresh and apply the per-domain `variance_multiplier` when constructing each domain's
  `Uncertain(mean, variance)` confidence (foundation gap #3). Refresh cadence is separate from the
  topology freeze.
- [ ] 2.4 Verify the widened variance lowers the domain's inverse-variance fusion weight (§4.3) on the
  next tick (assert the fused verdict shifts when one domain's variance is widened).
- [ ] 2.5 Emit/observe calibration state changes (log/metric) so operators can see which domains are
  currently down- or up-weighted, and provide a shadow/manual-override path before auto-apply.
- [ ] 2.6 Tests: a domain with a high false-positive label rate has its variance widened and its fusion
  weight reduced; a domain with confirmed true positives tightens toward the floor.

## 3. ATT&CK technique tag model + backfill on S1–S7

- [ ] 3.1 In `rust/causal-model`, ensure the `AttckTechnique` vocabulary + `EvidenceRef.attck` field
  (from the foundation `SecVerdict` model) are populated end-to-end; add the tag-declaration surface each
  causaloid uses.
- [ ] 3.2 In `rust/causal-causaloids`, declare the ATT&CK technique tag(s) per causaloid and backfill all
  of S1–S7 (S1 → T1071/T1568; S2 → T1041/T1567; S3 → T1021; S4 → T1190; S5 → T1557; S6 → T1595;
  S7 → T1110), matching the §6 catalog.
- [ ] 3.3 Populate `EvidenceRef.attck` on every emitted evidence unit during S1–S7 evaluation.
- [ ] 3.4 In `rust/causal-emit`, render the verdict as a labeled kill-chain step naming the ATT&CK
  technique and its tactic/stage in the `signals.analytics.predictions.*` payload; verify tags survive
  the `AnalyticsSignals` → `ocsf_events` path onto the resulting alert.
- [ ] 3.5 Document the bounded-catalog caveat (§0) and budget ongoing per-technique authoring: a technique
  in an unmodeled domain is untagged/invisible until a causaloid is authored; record this as recurring
  work, not a one-time backfill.

## 4. Validation

- [ ] 4.1 `openspec validate add-causal-detection-feedback --strict` passes.
- [ ] 4.2 End-to-end: an S1 verdict is tagged T1071, renders as a labeled kill-chain step on the alert,
  an analyst labels it false-positive, and the calibration loop widens the offending domain's variance on
  the next recompute.
- [ ] 4.3 Confirm no DDL is issued from the Rust engine (calibration table is Ash-managed; engine reads
  only).
