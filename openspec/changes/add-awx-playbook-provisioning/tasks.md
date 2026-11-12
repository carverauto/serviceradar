## 1. Decisions and prerequisites

- [ ] 1.1 Owner resolves the Open Decisions in `design.md`.
- [ ] 1.2 Land or absorb tasks 2.1 to 2.4 of `add-declarative-ansible-provisioning` (managed-object ownership, provisioning permission and credential purpose, typed agent commands, exact request-body custody).
- [ ] 1.3 Amend the sentence "The settings UI SHALL expose controller and repository management only" where it lives when this lands (the open `remove-legacy-ansible-ui` delta or the archived `build-web-ui` spec), and search `openspec/` for other copies first.
- [ ] 1.4 Verify on a synthetic controller, for each supported AWX version: project pinned to a commit hash with update-on-launch off; the synced revision as reported back; the role set of Decision 5; the survey shape the marker contract requires.
- [ ] 1.5 File the entries of `defects.md` as separate issues. They are not part of this change; section 4 delivers only the readiness, address-on-approval and membership listing this change specifies; the quarantine release and reason are in `add-awx-membership-quarantine-release`. Defect 2 needs an owner decision (whether a host that reappears after expiry requires re-approval) before it can be fixed.

## 2. Repositories, catalog and automations

- [ ] 2.1 Record the resolved commit and per-file SHA-256 on repository sync; expose them in the repository API and Terraform resource.
- [ ] 2.2 Parse `serviceradar.automation.catalog/v1` files, including the `automations` section, at the resolved commit; reject unknown schema versions.
- [ ] 2.3 Add the `Automation` and immutable `AutomationRevision` resources with audit versions, guarded deletion and the content digest.
- [ ] 2.4 Implement the typed input schema: field types, constraints, all-or-none groups, forbidden names, no secret type.
- [ ] 2.5 Ship the first-party repository URL and per-release tested commit as code defaults; registration stays an explicit action.

## 3. Provisioning

- [ ] 3.1 Add the `provisioning` controller credential purpose through the AWX package manifest, a restrictive foreign key and the credential usage inventory.
- [ ] 3.2 Add typed verbs with explicit endpoint mappings and one-mutation grants: project find/create, project update start/read, template find/create, survey set, credential attach, role grant/revoke, owned-object delete. The launch endpoint is unreachable under this purpose.
- [ ] 3.3 Render the AWX survey from the input schema and the dispatch-marker contract.
- [ ] 3.4 Implement the durable provisioning sequence with deterministic names, per-step idempotency, unresolved-outcome handling and resumption.
- [ ] 3.5 Read back with the execution principal and compute the projection digest.
- [ ] 3.6 Hand off to binding review "prepare" once per owned template, with the revision's content digest and input schema; never approve.
- [ ] 3.7 Implement plan (dry description of what will be created) without any upstream call that mutates.

## 4. Readiness and memberships

- [ ] 4.1 Compute target readiness from the launch predicates, reporting the first applicable reason in the order of Decision 10, including the address requirement.
- [ ] 4.2 Record hosts the collector skipped for lack of an anchor so readiness can report them.
- [x] 4.3 Moved: the reviewed quarantine release and the recorded quarantine reason are delivered by `add-awx-membership-quarantine-release`. Readiness (4.1) reports that reason and names the release as the remedy.
- [ ] 4.4 Refuse approval of a membership that has no address, with a specific error.
- [ ] 4.5 Add membership listing by device and of non-current rows, with full non-secret evidence.

## 5. Drift, retirement and deletion

- [ ] 5.1 Read-only reconciliation of owned objects with states `in_sync`, `drifted`, `missing`, `unresolved`.
- [ ] 5.2 Replace for a drifted or missing job template (new generation from the same revision and project) and Release (drop ownership, revoke bindings); a drifted or missing project blocks provisioning at its commit until restored or released, and is never replaced or duplicated.
- [ ] 5.3 Retirement of superseded generations with the operation guard; guarded deletion of automations, repositories and controllers.

## 6. API, Terraform, UI, permissions, audit

- [ ] 6.1 Add the resources of Decision 13 to the admin API and OpenAPI, following the open change's idempotency, concurrency and error conventions.
- [ ] 6.2 Register `ansible.controllers.provision` usage for the new actions; require a human principal; test the real authentication pipeline, read-only tokens and revoked users.
- [ ] 6.3 Terraform: `serviceradar_ansible_automation`, catalog and reference data sources; apply provisions and waits, never approves or launches; refresh is read-only.
- [ ] 6.4 UI: Automations tab, plan and progress, drift and retire; membership review page; binding review and renewal from the automation; readiness on the launch page and device panel. No database reads in disconnected mount; exact permission checks per event.
- [ ] 6.5 Emit the audit events of Decision 13, including membership approval and binding approval.

## 7. Worked example

- [ ] 7.1 Add the agent package catalog entry (two variants, three inputs, check mode) to the public playbook repository through its own review.
- [ ] 7.2 Route targets to a variant by package family when known.
- [ ] 7.3 Document the end-to-end procedure and the AWX prerequisites that remain.

## 8. Verification

- [ ] 8.1 Unit and database tests with invented controllers, hosts, addresses and identifiers; unboxed tests delete what they create.
- [ ] 8.2 Synthetic AWX compatibility suite: clean provision, retry after a lost create response, partial failure and resume, drift of each owned field, deletion out of band, denied mutations under each purpose, launch attempt under the provisioning purpose refused.
- [ ] 8.3 Prove nothing is launchable after provisioning without approval, by API, Terraform and UI.
- [ ] 8.4 Prove readiness and launch agree for every reason in Decision 10.
- [ ] 8.5 Terraform acceptance: no-op second apply, drift visible on refresh, guarded destroy, secret-free plan and state.
- [ ] 8.6 Explicitly requested canary of the worked example on a selected environment, check mode then run; verify by the package version on the specific hosts after the run started. Captured output never becomes a fixture.
- [ ] 8.7 Run `openspec validate add-awx-playbook-provisioning --strict`, focused Elixir and Go checks, and the required Bazel suite; report every check not run.
