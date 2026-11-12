## 1. Specification

- [x] 1.1 Write the proposal, design and deltas; validate with `openspec validate add-awx-membership-quarantine-release --strict`.
- [x] 1.2 Amend `add-awx-playbook-provisioning` so it does not describe a second quarantine release: drop its "Quarantine has a reviewed exit" requirement, point its readiness table, design, proposal, task 4.3 and defects 1 and 15 at this change.

## 2. Storage

- [x] 2.1 Migration: add `quarantine_reason` and `quarantined_at` to `platform.ansible_awx_host_memberships`; mark every existing quarantined row `predates_reason_recording` with no time; add the reason-value and reason/time consistency check constraints.
- [x] 2.2 Same migration: replace `platform.trg_ansible_awx_membership_device_deleted()` so it also sets `canonical_device_deleted` and the deletion time.
- [x] 2.3 Same migration: create the append-only `platform.ansible_awx_membership_quarantine_releases` table with its indexes.
- [x] 2.4 Move `core.migrations.expectedVersion` in `helm/serviceradar/values.yaml` to the new migration version.

## 3. Core

- [x] 3.1 `AwxHostMembership`: add the two attributes, accept them in `upsert_from_sync`, add the human-only `release_quarantine` action with an atomic compare-and-swap change, and remove the unused `quarantine_link` action.
- [x] 3.2 `AwxMembershipReconciler`: set the reason and observation time at each quarantine rule, keep the first reason and time on a sticky row, include both in the authority comparison and the same-generation upsert condition, and expose the current-match lookup used by release.
- [x] 3.3 Extract the shared reviewer authority and request parsing from `AwxMembershipApproval` without changing approval's error codes.
- [x] 3.4 Add the release service: request binding, fresh human authority, the controller observation lock, current-match evaluation, the membership update and the release record in one transaction.
- [x] 3.5 Add the `AwxMembershipQuarantineReleaseRecord` resource (create and read only) to the Ansible domain.

## 4. API and documentation

- [x] 4.1 `ServiceRadarWebNG.AnsibleAutomation.release_membership/3`; include `quarantine_reason` and `quarantined_at` in the membership view.
- [x] 4.2 Route `POST /api/admin/ansible-memberships/{id}/release` as a human, `ansible.controllers.manage` action; return the matching devices on an ambiguity refusal.
- [x] 4.3 OpenAPI: the release path and request schema, the two new membership fields.
- [x] 4.4 Docs: `docs/docs/ansible-provisioning-api.md` (release request and outcomes) and `docs/docs/ansible.md` (reasons, stickiness, release, distinction from target holds).

## 5. Tests

- [x] 5.1 Reconciler unit test: each quarantine rule records its reason and observation time; a sticky row keeps its first reason; a released row is quarantined again with a new reason.
- [x] 5.2 Release integration test against the database: one match to `proposed` and a normal approval afterwards; no match to `unlinked`; several matches refused and unchanged; stale evidence and non-human callers refused; one release record per success; the storage constraint rejects a quarantined row without a reason.
- [x] 5.3 Device purge test: the trigger records `canonical_device_deleted`.
- [x] 5.4 web-ng: OpenAPI document and controller authority for the release route.

## 6. Follow-up: settings UI (after the membership review modal change merges)

- [ ] 6.1 In Settings -> Ansible -> Memberships, show the reason and time on quarantined rows, with an operator-facing label per reason; `predates_reason_recording` and a missing time read as unknown.
- [ ] 6.2 Offer a **Release quarantine** control on quarantined, current rows to users holding `ansible.controllers.manage`; re-check that permission from persisted authority on the event; confirm in the review dialog showing the row's evidence; submit exactly the displayed six fields through `AnsibleAutomation.release_membership/3`.
- [ ] 6.3 On success, reload the row (now `proposed` or `unlinked`) and offer the normal approval for a proposal. On `membership_link_ambiguous`, show the matching devices and keep the row; on changed evidence, reload and show the current evidence; never resubmit automatically.
- [ ] 6.4 Label it "membership quarantine" and state that a released membership needs approval; do not confuse it with a device target hold.
- [ ] 6.5 LiveView tests for the reason display, the release flow, both refusals and the authority re-check; update the operator guide's membership steps.
