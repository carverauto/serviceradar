# Tasks: Native add-on Edge Ops targeting & reconciliation

> Implements the remaining reporting/UI tasks from `add-agent-feature-sets`. Task
> numbers in parentheses map back to that change.

> **In progress** (branch `feat/native-addon-edge-ops`). The status read model (7.2)
> is implemented; the Edge Ops UI surfaces (8.x) need a browser/LiveView environment
> to build and verify and are not done here.

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
- [ ] 1.2 Surface per-agent add-on status via SRQL where relevant. (§7.2)
  — Status: partial — the read model is an Ash resource (queryable via the Ash API);
  registering a dedicated `addon_statuses` SRQL entity in the Rust SRQL service
  (schema.rs + query executor + dispatch) is a follow-up.

## 2. Edge Ops UI
- [ ] 2.1 Approval-review surface for a staged `AddonPackage` (manifest, capabilities,
  delivery/supervision, provenance); approve/deny with `approved_capabilities`
  narrowing. (§8.2)
- [ ] 2.2 Per-cohort targeting (reuse the release cohort + compatibility-preview
  pattern), alongside per-agent assignment. (§8.4)
- [ ] 2.3 Per-agent detail: assigned vs. installed vs. active add-ons + drift
  surfacing. (§8.5)
- [ ] 2.4 Onboarding: select an initial feature set in the onboarding package
  flow. (§8.6)

## 3. Docs
- [ ] 3.1 Operator docs: how to select/target feature sets in Edge Ops. (§10.2)

## 4. Validation
- [x] 4.1 `openspec validate add-native-addon-edge-ops --strict` passes.
- [ ] 4.2 Tests: read-model parse of a reported add-on status payload; cohort assignment
  fans out to cohort members; drift card reflects an unhealthy/arch-unsupported add-on.
  — Status: partial — read-model parse is covered (addon_status_ingestor_test.exs:
  addon sidecars parsed, non-addon sidecars ignored, re-ingest upserts). Cohort/drift
  tests land with the UI (8.x).
