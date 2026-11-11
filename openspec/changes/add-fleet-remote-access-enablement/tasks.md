## 1. Decisions and prerequisites

- [ ] 1.1 Owner resolves the Open Decisions in `design.md`; update the spec deltas where a choice differs from the recommendation.
- [ ] 1.2 Resolve each item under "Not established from the code" in `design.md` that a later task depends on (credential record for a CA, rule identities per integration, exact single-device query, Proxmox privilege names on a test cluster, stock sshd activation per supported release) and record the answers in `design.md`.
- [ ] 1.3 File the items in `defects.md` as issues. They are fixed outside this change.
- [ ] 1.4 Threat-model the readiness probe and central host-key delivery under the review gate of `harden-remote-access-security`.

## 2. Access rules, CA records and principals

- [ ] 2.1 Add credential kind `ssh_user_ca` with public key, fingerprint and signer reference; creation from Settings and the admin API; guarded deletion while a rule references it.
- [ ] 2.2 Add the `ssh_certificate` rule content (accounts with mode, lifetime, `allow_elevated_targets`) and its validation for rules with provider `ssh`, auth method `ssh_certificate`, purpose `remote_access`, including the required actor-use policy and host-key policy.
- [ ] 2.3 Implement the exact single-device membership test for a rule's target query and the routing-agent scope test.
- [ ] 2.4 Implement rule selection (first qualifying rule by priority then creation time) and replace the app-env policy lookup in certificate authorization with it.
- [ ] 2.5 Add device accounts and principals as Ash resources with one current principal, at most one previous principal with its origin (`rotation`, `import`, `merge`), generation, rotation, revocation and origin-device tracking; generate principals from a cryptographic random source.
- [ ] 2.6 Implement the reconciler that derives device accounts from enabled rules over the whole inventory, paged, on rule change and on a schedule, maintains the per-device enrollment generation, and revokes the principals of undesired device accounts at once and marks them pending removal.
- [ ] 2.7 Issue certificates with only the device account's non-revoked principals; remove claim-to-principal mapping from the issuance path.
- [ ] 2.8 Add the runtime setting for local certificate identity with audit.
- [ ] 2.9 Implement classified certificate failures and their remedies in core, the agent error path and the console.
- [ ] 2.10 Extend device merge, unmerge and delete handling to device accounts, principals, enrollment records and readiness state; report rules whose coverage lost a merged-away device.
- [ ] 2.11 Settings UI for access rules and CA records within the credentials area; expose rule content in the admin API and the `network_credential_rule` Terraform resource.
- [ ] 2.12 Audit events for every action listed in "Certificate access audit"; verify no principal appears outside the enrollment bundle.

## 3. Migration of the file-based policy

- [ ] 3.1 Implement the one-time import with its report and digest record: rule content validation, splitting of entries above 16 accounts, disabled import of rules that fail a check, and a CA record that keeps the existing signer reference.
- [ ] 3.2 Attach each device account's single legacy principal as its previous principal with origin `import`, report device accounts with none, and schedule their single probe.
- [ ] 3.3 Release N for `remoteAccess.sshCertificatePolicy` (the import release): read the value only for the import, and warn in Helm and at workload boot that it is ignored.
- [ ] 3.4 Release N+1: remove the value, its helper validation and its mount, fail rendering while it is set, and end the legacy probe allowance.

## 4. Readiness and the probe

- [ ] 4.1 Store per-device-account readiness state, reason and evidence as defined in "Per-device-account readiness state", and reject any state and reason pair, or writer, outside that requirement's lists.
- [ ] 4.2 Issue probe certificates (system-issued, exactly one principal, at most 60 seconds, forced no-op command, no permit extensions, probe key ID).
- [ ] 4.3 Agent: probe connection that authenticates and disconnects without requesting a channel, current principal first and previous principal second, classified results, per-agent rate limit; advertise the capability. Retire the previous principal only on success with the current principal alone.
- [ ] 4.4 Schedule probes after enrollment results, on request, once for legacy principals and periodically; runtime setting for the interval.
- [ ] 4.5 Gate certificate issuance on state `verified`, plus the legacy probe allowance (`pending`/`probe_unsupported`) and its end when the agent can probe or at release N+1.
- [ ] 4.6 Device remote-access surface: accounts, state, reason, remedy, readiness check; Connect only where the issuance gate admits.
- [ ] 4.7 Settings enrollment view with counts by state and reason, rule filter and API export.

## 5. Central host-key trust

- [ ] 5.1 Add source `enrollment` and device-keyed lookup to the host-key store; record keys from enrollment results for devices with no trusted key.
- [ ] 5.2 Deliver a device's trusted keys in the authenticated session and probe instructions.
- [ ] 5.3 Agent: verify against delivered keys, restrict host-key algorithms to them, do not read or write the local file when keys are delivered; advertise the capability.
- [ ] 5.4 Unknown and changed key handling with readiness reasons, audit and events.
- [ ] 5.5 Authorized host-key change for a device or a rule's devices, time-bounded, consumed on first use; direct conflict resolution.
- [ ] 5.6 Console approval of an unknown key writes to the central store and requires `settings.remote_access_host_keys.manage`.
- [ ] 5.7 Move host-key records on merge and return them on unmerge.

## 6. Enrollment bundle and channels

- [ ] 6.1 Bundle projection per device and its admin API under `devices.remote_access.ssh.ca_bundle.read`.
- [ ] 6.2 Enrollment classification: `standard`, `elevated` from the stored virtualization host relationship, administrator exclusion.
- [ ] 6.3 Enrollment result ingestion: admin API endpoint with `devices.remote_access.ssh.enrollment.report` for the direct channel; host-scoped job events for the integrated channel.
- [ ] 6.4 Manual channel: per-device instructions rendered from the bundle.
- [ ] 6.5 Stored-bundle callback response-policy provider; remove the file-backed provider. In that release (N for `automationCallbacks.responsePolicy`) ignore the value with a warning; in release N+1 remove it and fail rendering while it is set.
- [ ] 6.6 Integrated launch: select device accounts by rule and state, map to approved AWX memberships, partition within the per-child limit, report non-launchable devices with their AWX readiness reason.
- [ ] 6.7 Rewrite `docs/docs/remote-access.md` enrollment sections and `docs/ansible/remote-access-ssh-ca/` to the single layout and the three channels, with invented example values only.

## 7. Public enrollment content (repository `serviceradar-ansible`)

- [ ] 7.1 Adoption of the two recognized earlier layouts inside the enroll transaction.
- [ ] 7.2 Account modes `existing` and `managed`; the enroll transaction deletes principals files of accounts the bundle omits.
- [ ] 7.3 Risk class `elevated` with hypervisor detection and one-host-at-a-time execution.
- [ ] 7.4 Stock-configuration support for every declared release, including its default sshd activation mode.
- [ ] 7.5 Structured results with host public keys in both modes.
- [ ] 7.6 Inventory plugin for direct mode and the guard against values from other sources.
- [ ] 7.7 Remove `fleet_ssh_enroll` with a migration note.
- [ ] 7.8 Test matrix: stage, verify, commit, rollback, adoption of each earlier layout, managed accounts, virtual machine and system container for each release, the elevated class.

## 8. Proxmox console

- [ ] 8.1 Rule coverage from the stored relationship with the exact membership test of 2.3 for the requested device and its owning host.
- [ ] 8.2 Scope evaluation against the agent holding the controller's active assignment.
- [ ] 8.3 Classified denial reasons with the nearest-miss rule and permission-dependent detail.
- [ ] 8.4 Credential verification through the PVE API on request and on rule or credential change.
- [ ] 8.5 Console readiness on host and guest device surfaces.
- [ ] 8.6 Document the minimal privilege set, role definition and commands in `docs/docs/proxmox.md` after 1.2 confirms them.

## 9. Verification

- [ ] 9.1 Load the `test-audit` skill before writing tests; every test that commits rows deletes them.
- [ ] 9.2 Tests for each spec scenario in sections 2 to 6 and 8, including two devices sharing a hostname, a rule larger than the preview sample, merge and unmerge, rule disable and re-enable, and probe classification.
- [ ] 9.3 Agent tests for delivered host keys, the probe without a channel, the single-principal probe during rotation against a host that lists only the previous principal, and capability fallback.
- [ ] 9.4 Helm unit tests for both retired values in their release N (renders with a warning) and N+1 (refuses to render while set).
- [ ] 9.5 End-to-end: direct channel against test hosts of each supported release from an empty deployment to a verified session, with no hand-written host variable.
- [ ] 9.6 Run `openspec validate add-fleet-remote-access-enablement --strict` and report every check not run.
