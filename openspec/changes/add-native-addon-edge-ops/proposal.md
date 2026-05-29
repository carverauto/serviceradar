# Change: Native add-on Edge Ops targeting & reconciliation

## Why
The framework (`add-agent-feature-sets`) landed the Edge Ops add-on catalog, the
per-agent config form, and a per-agent assignment card. What remains for operators to
run add-ons at fleet scale is: an approval-review surface for staged packages,
per-cohort targeting (reusing the release cohort + compatibility-preview pattern), a
desired-vs-active drift view, and an onboarding-time feature-set selection. The agent
already reports per-add-on status upward, but the control plane does not yet parse it
into a read model, so the UI cannot show what is actually installed/active.

## What Changes
- **Per-agent add-on status read model**: parse the per-add-on
  installed/available/active/unhealthy state (with reason + arch) the agent reports in
  its capability status into the agent registry read model, and expose it via SRQL
  where relevant.
- **Approval review UI**: review a staged `AddonPackage`'s manifest, capabilities,
  delivery/supervision model, and provenance, and approve/deny — narrowing
  `approved_capabilities` on approval.
- **Per-cohort targeting**: assign an add-on to a cohort, reusing the agent-release
  cohort selection + compatibility-preview pattern, in addition to per-agent.
- **Drift view**: on the per-agent detail, show assigned vs. installed vs. active
  add-ons and surface drift (assigned-but-not-active, unhealthy, arch-unsupported).
- **Onboarding feature-set selection**: allow selecting an initial feature set in the
  onboarding package flow so a newly onboarded agent comes up with add-ons assigned.

## Impact
- **Depends on:** `add-agent-feature-sets` (catalog/assignment + agent status reporting).
- **Affected specs:** ADDED requirements to `agent-registry` (add-on status read model)
  and `build-web-ui` (approval review, cohort targeting + drift, onboarding selection).
- **Affected code:** `elixir/serviceradar_core` agent registry read model + SRQL
  surfacing of the reported add-on status; `elixir/web-ng` Edge Ops LiveViews (approval
  review, cohort targeting reusing the release cohort/compatibility-preview components,
  per-agent drift card), and the onboarding package flow.
- **Operator docs:** how to select/target feature sets in Edge Ops (3425 §10.2).
