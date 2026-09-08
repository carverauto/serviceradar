# Tasks: Native add-on Edge Ops targeting & reconciliation

> Implements the remaining reporting/UI tasks from `add-agent-feature-sets`. Task
> numbers in parentheses map back to that change.

> **Complete.** The status read model, SRQL entity, Edge Ops approval/targeting UI,
> per-agent drift view, onboarding initial add-on assignment, operator docs, and
> targeted tests have landed.

## 1. Status read model
- [x] 1.1 Parse the per-add-on installed/available/active/unhealthy state (reason +
  arch) reported in the agent capability status into the agent registry read
  model. (3425 §7.2)
  — `ServiceRadar.Plugins.AddonStatus` (platform schema, keyed {agent_uid, addon_id})
  + `AddonStatusIngestor`, hooked into `StatusHandler` for the agent capability status
  (service_name "agent"): the `addon:<id>` sidecar entries are parsed into the read
  model with state, active, degradation_reason, pid, restart_count, last_health_at.
  `version`/`arch` columns exist but are nullable — the agent does not yet report them
  per add-on (task 7.1, agent-side enrichment).
- [x] 1.2 Surface per-agent add-on status via SRQL where relevant. (§7.2)
  — `in:addon_statuses` is a first-class SRQL entity in the Rust srql crate (the live
  in-process NIF translate path): `Entity::AddonStatuses` + parse mapping (parser.rs),
  the `addon_statuses` Diesel table (schema.rs), `AddonStatusRow` (models.rs), and a
  `query/addon_statuses.rs` executor (filters: agent_uid/addon_id/state/version/arch;
  default `reported_at` desc), wired into both dispatch matches and the viz metadata.
  Verified by `cargo test` (translation is pure, no DB): full srql suite 179/0.

## 2. Edge Ops UI
- [x] 2.1 Approval-review surface for a staged `AddonPackage` (manifest, capabilities,
  delivery/supervision, provenance); approve/deny with `approved_capabilities`
  narrowing. (§8.2)
- [x] 2.2 Per-cohort targeting (reuse the release cohort + compatibility-preview
  pattern), alongside per-agent assignment. (§8.4)
- [x] 2.3 Per-agent detail: assigned vs. installed vs. active add-ons + drift
  surfacing. (§8.5)
- [x] 2.4 Onboarding: select an initial feature set in the onboarding package
  flow. (§8.6)

## 3. Docs
- [x] 3.1 Operator docs: how to select/target feature sets in Edge Ops. (§10.2)

## 4. Validation
- [x] 4.1 `openspec validate add-native-addon-edge-ops --strict` passes.
- [x] 4.2 Tests: read-model parse of a reported add-on status payload; cohort assignment
  fans out to cohort members; drift card reflects an unhealthy/arch-unsupported add-on.
  — Status: partial — read-model parse is covered (addon_status_ingestor_test.exs:
  addon sidecars parsed, non-addon sidecars ignored, re-ingest upserts). Cohort/drift
  tests land with the UI (8.x). Cohort compatibility + fan-out are covered by
  `addon_package_live_test.exs`; unhealthy and architecture-unsupported drift are
  covered by `agent_live/show_test.exs`.
