## 1. Specification

- [x] 1.1 Add the membership review, binding review, and authority-gate requirements to `ansible-integration`.
- [x] 1.2 Amend the pending `remove-legacy-ansible-ui` settings requirement so Ansible settings may host membership and binding review; keep its retained-internals prohibition.
- [x] 1.3 Run `openspec validate add-ansible-review-ui --strict` and `openspec validate remove-legacy-ansible-ui --strict`.

## 2. Settings UI

- [x] 2.1 Add Memberships and Template bindings tabs to `/settings/ansible` and the settings catalog, gated by `ansible.controllers.manage`, with inert disconnected-mount state.
- [x] 2.2 Memberships: controller and inventory pickers with per-inventory needs-review counts, filters, a streamed table, a review panel showing the full evidence tuple, approval of exactly that tuple, and reload plus re-review on a changed proposal.
- [x] 2.3 Show the reason each unlinked, quarantined, disabled, ambiguous, or approved membership cannot be approved; offer no force-link control.
- [x] 2.4 Template bindings: controller and template pickers, streamed version list, request form with approved-membership choices and catalog-suggested IDs, asynchronous prepare, review panel with digest, create bound to `expected_review_digest`, automatic re-preparation on a changed review, and typed-confirmation revoke.
- [x] 2.5 Route every mutation through `ServiceRadarWebNG.AnsibleAutomation` with the session scope after re-checking `ansible.controllers.manage`; add only scoped read helpers for the pickers.

## 3. Documentation

- [x] 3.1 Update `docs/docs/ansible.md` with where to approve memberships and review bindings, and remove the "not yet rendered" note.
- [x] 3.2 Note in `docs/docs/ansible-provisioning-api.md` that the settings UI drives the same review contract for human users.

## 4. Verification

- [x] 4.1 LiveView tests: approval submits the shown tuple and a changed proposal is re-shown; create submits the prepared digest and a changed review is not accepted; typed revoke confirmation; a user who loses `ansible.controllers.manage` cannot approve, create, or revoke by sending events.
- [x] 4.2 Register the new test file in its web-ng DB shard and the runner contract.
- [ ] 4.3 Verify on a live deployment with a real AWX controller (requires a database and AWX; not run in this change).
