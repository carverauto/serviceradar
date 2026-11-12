# Change: Record why AWX memberships are quarantined, and let a human release them

## Why

An AWX host membership can be `quarantined`, and nothing records which rule put it
there. The operator sees the disposition and nothing that explains it. Quarantine is
also permanent: inventory synchronization keeps a quarantined row quarantined on every
later observation, approval accepts only `proposed`, and no action leaves the state. A
quarantined host therefore stays unlaunchable after the ambiguity or device change that
caused it is resolved, and the only remedy is outside the product.

The owner approved two changes:

1. Record the reason whenever a host is quarantined, and show it on the row.
2. Add a human "release quarantine" action that puts the host back to proposed with its
   current evidence, so it still needs a normal approval afterwards.

## What Changes

- Memberships carry a typed `quarantine_reason` and a `quarantined_at` time. Every
  writer that quarantines sets them: the four rules of inventory reconciliation
  (`ambiguous_device_match`, `approved_device_changed`, `approved_link_lost_match`,
  `approved_membership_not_current`) and the database trigger that quarantines an
  approved membership whose canonical device was deleted or purged
  (`canonical_device_deleted`). Storage rejects a quarantined row without a reason.
- Quarantine stays sticky. Synchronization never clears it, and a sticky row keeps the
  reason and time that first quarantined it. Release is the only exit.
- Existing quarantined rows are marked `predates_reason_recording` with no time. Their
  cause was never stored and is not inferred.
- A human principal holding `ansible.controllers.manage` can release one quarantined
  membership by submitting the exact evidence shown. Release re-evaluates the AWX
  source tuple against current device inventory: exactly one match makes the row
  `proposed` with fresh evidence, which still requires a normal approval; no match
  makes it `unlinked`; more than one match is refused and the row stays quarantined.
  Release never produces `approved`.
- Every release appends one record: who, when, the prior reason and time, the evidence
  at release, and the resulting disposition and evidence.
- The admin API adds `POST /api/admin/ansible-memberships/{id}/release`, and membership
  reads include the reason and time. The OpenAPI document and the Ansible docs describe
  both.
- The unused `quarantine_link` action is removed, so no writer can quarantine without a
  reason.
- Follow-up, not in the first pull request: the Ansible settings membership review
  shows the reason on quarantined rows and offers the release. It waits for the
  in-flight review-modal change to the same LiveView.

No **BREAKING** change. The release route and response fields are additive; a client
that ignores the new fields is unaffected.

## Impact

- Affected specs: `ansible-awx-targeting` (added requirements), `ansible-integration`
  (added UI requirement, implemented as a follow-up).
- Amended pending change: `add-awx-playbook-provisioning` delegated its "Quarantine has a
  reviewed exit" requirement and task 4.3 to this change; its readiness table and design
  now point here instead of describing a second release.
- Affected code: `AwxHostMembership`, `AwxMembershipReconciler`,
  `AwxMembershipApproval`, the observation fence, a new release service and release
  record resource, `ServiceRadarWebNG.AnsibleAutomation`, the Ansible admin API
  controller, router and OpenAPI document.
- Schema: one migration adds the two membership columns and their constraints, marks
  existing quarantined rows, updates the deleted-device trigger, and adds
  `platform.ansible_awx_membership_quarantine_releases`.
- Docs: `docs/docs/ansible.md`, `docs/docs/ansible-provisioning-api.md`.

## Not this change

- `AutomationTargetHold` is a different, device-wide hold after a failed mutation.
  Releasing a membership does not clear a hold, and clearing a hold does not release a
  membership.
- Whether an approved host that reappears after expiry should keep its approval
  (`add-awx-playbook-provisioning` defect 2) is still an owner decision. This change
  records that case as `approved_membership_not_current` and gives it the same release
  exit; it does not change the policy.
