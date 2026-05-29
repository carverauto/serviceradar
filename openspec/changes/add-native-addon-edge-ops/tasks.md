# Tasks: Native add-on Edge Ops targeting & reconciliation

> Implements the remaining reporting/UI tasks from `add-agent-feature-sets`. Task
> numbers in parentheses map back to that change.

## 1. Status read model
- [ ] 1.1 Parse the per-add-on installed/available/active/unhealthy state (reason +
  arch) reported in the agent capability status into the agent registry read
  model. (3425 §7.2)
- [ ] 1.2 Surface per-agent add-on status via SRQL where relevant. (§7.2)

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
- [ ] 4.1 `openspec validate add-native-addon-edge-ops --strict` passes.
- [ ] 4.2 Tests: read-model parse of a reported add-on status payload; cohort assignment
  fans out to cohort members; drift card reflects an unhealthy/arch-unsupported add-on.
