## 1. Public repository structure

- [ ] 1.1 Add Apache-2.0 `LICENSE`, README, changelog, `galaxy.yml`, `meta/runtime.yml`, typed defaults, and non-secret examples in `/Users/mfreeman/src/serviceradar-ansible-remote-access`.
- [ ] 1.2 Add `roles/remote_access_ssh_ca`, the controller-only callback helper, reusable playbooks, and separate root wrappers for direct/operator-managed and integrated preflight, staged enroll/rotate, fresh-connection verify/commit, and absent/offboarding.
- [ ] 1.3 Add reviewed catalog metadata binding only the non-downgradable integrated wrapper paths, declared callback action/schema, supported platforms, public variables, and check-mode behavior; document direct mode without ServiceRadar authorization/readiness claims.

## 2. Enrollment role

- [ ] 2.1 Implement exact platform/OpenSSH/systemd/SELinux/FIPS/layout validation; reject root/UID0, login-disabled/unsupported accounts, higher-risk targets without separate policy, unsafe parents/symlinks, unmanaged policy, invalid keys/fingerprints/principals/paths, and private material.
- [ ] 2.2 Implement role-owned public CA bundle and tuple-selected target-specific principal rendering with multi-key overlap; require integrated fresh new-CA edge proof plus `devices.remote_access.ssh.ca_trust.retire`, or direct controller-owned new-CA credential proof plus explicit fingerprint confirmation, for separate retirement jobs.
- [ ] 2.3 Implement baseline/candidate/live `sshd -t`, account/Match-aware `sshd -T -C`, atomic install, reload-only stage behavior, current-connection preservation, a target/transaction/generation/policy-bound persistent systemd rollback+boot guard, one-pending-mutation locking, race-safe separate SSH-machine-credential verification/commit, full absence/content/owner/mode/ACL/SELinux restoration, and machine-readable critical abort on failed rescue.
- [ ] 2.4 Implement accurate check mode, second-run idempotence, verification output, and bounded `state: absent` removal of role-owned files only.

## 3. Callback consumer

- [ ] 3.1 Consume the ephemeral custom credential only on the reviewed AWX execution environment with built-in `uri`, `use_proxy: false`, strict transport/schema checks, server/egress-proxy response cap, `run_once`, `delegate_to: localhost`, `changed_when: false`, and `no_log: true`.
- [ ] 3.2 Require `ansible.runs.launch` plus `devices.remote_access.ssh.ca_bundle.read`, exact policy/approval/template/revision/custom-credential binding, immutable `(controller, inventory, AWX host ID, canonical device UID)` tuples, and exact play-host/target set equality; reject hostname/IP/fact/survey/extra-var relabeling and any integrated-to-direct downgrade before host change.
- [ ] 3.3 Test that callback values do not persist in job output/events, host facts/cache, artifacts, failure/support data, backups, relaunch/copy inputs, or managed hosts; verify ephemeral credential deletion, grant revocation, and relaunch denial.
- [ ] 3.4 Require `devices.remote_access.ssh.ca_trust.remove` for integrated absent/offboarding and prove bundle-read permission alone cannot authorize retirement/removal; require documented operator-controller authorization plus explicit destructive confirmation for direct removal without claiming ServiceRadar authorization.

## 4. Quality and publishing

- [ ] 4.1 Pin Forgejo actions/runners, Molecule/OS images, Python/Ansible/lint dependencies, and add yamllint, ansible-lint, provenance, and syntax-check gates for every root wrapper.
- [ ] 4.2 Add real-sshd systemd-capable Molecule coverage for Ubuntu 22.04/24.04, Debian 12, and Rocky Linux 9, including SELinux/FIPS/layout/credential failures, root/account rejection, direct versus integrated mode isolation/authorization, clean install, check/idempotence, overlap/proof-gated retirement, removal, reboot/systemd-restart guard survival, stale/concurrent/timer-expiry commit races, separate original-credential verification/commit, full-metadata rollback, and machine-readable failed-rescue abort.
- [ ] 4.3 Run all lint, syntax, and Molecule gates and document the supported-version matrix and operator/AWX import workflow.
- [ ] 4.4 Generate test CA private keys ephemerally in CI only; confirm repository history, caches, logs, support output, and artifacts contain no deployment/test CA private key, callback grant, user/general API token, machine credential, or signer configuration.
- [ ] 4.5 Commit on `feat/serviceradar-remote-access-enrollment`, push with `git push origin feat/serviceradar-remote-access-enrollment:refs/heads/feat/serviceradar-remote-access-enrollment`, and open a public repository pull request.
- [ ] 4.6 After review, record the approved immutable commit/content hash for the separate ServiceRadar/AWX import and binding change; make no live AWX or host mutation in this child.
