## 1. Program discovery and approval boundary

- [x] 1.1 Inspect the live `demo` remote-access, AWX, Proxmox, inventory, agent, SSH, and RDP state without mutating targets or controllers.
- [x] 1.2 Validate read-only topology and access for the two SSH canaries, Farm PVE nodes, online Tonka PVE nodes, the controlled Windows target, and the in-cluster AWX controller.
- [x] 1.3 Create non-tracking feature worktrees for ServiceRadar and the public `serviceradar-ansible` repository without modifying shared branches.
- [x] 1.4 Record the architecture, security boundaries, conflicts, delivery children, rollout gates, and rollback requirements in this program proposal.
- [x] 1.5 Review and approve this program-level architecture and sequence. Approval does not authorize product code, live AWX mutation, CA generation/distribution, target configuration, console enablement, or demo rollout without the corresponding conflict-free child approval.

## 2. Prerequisite OpenSpec reconciliation

- [ ] 2.1 Land a separate archival-only PR that moves completed deployed remote-access foundations into canonical specs; do not combine archive operations with feature implementation.
- [ ] 2.2 Resolve the canonical audit contradiction between a secret credential-rule identifier and a non-secret policy/custody reference.
- [ ] 2.3 Amend `add-ansible-integration` with exact `MODIFIED` requirements for normalized multiple memberships, no hostname-derived strong identity, partitioned child launches, mandatory inventory/non-empty exact limits, target-count equality, check mode, host-ID result correlation, human audit, and secret references instead of persisted secret `extra_vars`.
- [ ] 2.4 Resolve whether IP-less Proxmox guests receive canonical Device rows or a virtualization-guest detail surface, then amend the reliability/identity proposals consistently.
- [ ] 2.5 Clarify versioned Device `integration_id` versus virtualization `provider_ref`, finish provider-instance migration prerequisites, and retain incomplete RDP/parity work under their existing owners.
- [ ] 2.6 Rebase every child delta on the reconciled canonical specs and use exact full `MODIFIED` requirements rather than parallel additive duplicates.

## 3. Child change: authoritative remote-access readiness

- [ ] 3.1 Create and approve `add-authoritative-remote-access-readiness` with versioned deployment/adapter and target evidence, freshness/invalidation rules, sanitized reasons, and atomic launch re-evaluation.
- [ ] 3.2 Make applied agent configuration plus signed compatible adapter/helper self-test drive local capability; remove compile-time-only RDP readiness and config acknowledgements that do not change effective state.
- [ ] 3.3 Keep SSH, PVE/LXC, QEMU, and RDP actions unavailable independently until each exact target/route/build/trust/credential proof is current.
- [ ] 3.4 Add evidence lifecycle, override-denial, stale-UI, route-reconnect, redaction, and terminal-cleanup tests.

## 4. Child changes: AWX targeting and callback grants

- [ ] 4.1 Create and approve `harden-ansible-awx-targeting` before any fleet mutation.
- [ ] 4.2 Normalize AWX identity as `(controller_id, inventory_id, host_id)`, preserve multiple memberships, expire/quarantine stale generations, and stop last-writer-wins metadata from selecting execution identity.
- [ ] 4.3 Partition one parent operation into exact controller/inventory/template child jobs; re-fetch IDs/addresses, validate template inventory, reject every empty-limit path, require target-count equality, and correlate results/events by child plus host ID.
- [ ] 4.4 Preserve the initiating human, exact target/inventory/limit/check-mode/revision snapshot, actual AWX jobs, and per-target outcomes; persist only public variables and secret references.
- [ ] 4.5 Create and approve `add-automation-callback-grants`, registering only `remote_access.ssh_ca.bundle.read` as bounded read-only internal target configuration with no secret material.
- [ ] 4.6 Require interactive and service principals to hold both `ansible.runs.launch` and exact permission `devices.remote_access.ssh.ca_bundle.read` before dispatch, and recheck the issuance ceiling plus current permissions/policy/approval on activation and use.
- [ ] 4.7 Implement pending-before-dispatch grants, exact AWX job binding/activation, mandatory target/policy/revision snapshots, atomic replay-safe one-read consumption, ambiguous-dispatch revocation, and secret-free durable audit.
- [ ] 4.8 Implement a reviewed ephemeral AWX custom credential injector and single-resolution authenticated envelope; prohibit survey/ordinary `extra_vars`, enumerate the dispatcher/AWX/EE trusted bearer boundary, and test all AWX retention/relaunch/backup surfaces.
- [ ] 4.9 Enforce server-selected canonical HTTPS, CA/hostname verification, no redirects or credential forwarding, bounded time/size/schema, reviewed immutable SCM/template bindings, revision verification, and execution-environment egress policy.
- [ ] 4.10 Define fixed non-wildcard service-principal ceilings and require a separate security proposal plus proof of possession for any future secret-returning, mutating, signing, or credential-minting action.
- [ ] 4.11 After both children land, use the user's authorized full AWX administration access to configure distinct `farm01` and `tonka01` inventories/sources, execution reachability, machine/become credentials, the public Project, pinned templates, and the ServiceRadar callback custom credential type.

## 5. Child change: public Ansible SSH-CA enrollment

- [ ] 5.1 Create and approve `publish-ssh-ca-ansible-enrollment` for the `/Users/mfreeman/src/serviceradar-ansible-remote-access` worktree.
- [ ] 5.2 Build root AWX-discoverable preflight, enroll/rotate, verify, and absent/rollback playbooks plus reusable `remote_access_ssh_ca` and callback helper roles using Ansible built-ins.
- [ ] 5.3 Support target-keyed opaque principals, multi-key overlap rotation, strict account/key/fingerprint/path/input validation, private-key rejection, distro/service/drop-in detection, unmanaged-CA conflicts, check mode, idempotence, `sshd -t`/`sshd -T`, reconnect proof, and atomic rescue rollback.
- [ ] 5.4 Add Apache-2.0 licensing, collection/runtime metadata, typed public variables, non-secret examples, catalog action/schema metadata, documentation, changelog, Forgejo lint/syntax gates, and Molecule Debian/Ubuntu/Rocky coverage for idempotence, rotation, removal, invalid input, and byte-identical rollback.
- [ ] 5.5 Push only the Ansible feature branch with an explicit refspec, open a pull request, and pin the reviewed revision/content hash for ServiceRadar/AWX import; never commit a deployment CA, callback token, machine credential, signer configuration, or private key.

## 6. Child change: complete agent-routed SSH

- [ ] 6.1 Create and approve `complete-ssh-certificate-access` after readiness, targeting, callback, and public-role prerequisites land.
- [ ] 6.2 Package the signer and Helm secret/config boundary, define CA rotation and target-specific principal policy, and keep the private CA key only in the signing boundary.
- [ ] 6.3 Generate each SSO keypair on the selected agent after atomic attach; sign one target/actor/session/account/route-bound public key with PTY-only extensions and a bounded authentication TTL; never send private material through browser or control-plane surfaces.
- [ ] 6.4 Prove cross-target and wrong-route denial, second-key rejection, host-key conflict handling, memory disposal, typed errors, lifecycle/audit/recording behavior, timeout, revocation, and route-loss cleanup.
- [ ] 6.5 Use read-only preflight/check, then enroll `192.168.2.22` and `192.168.1.62` as canaries, approve host keys, and require both effective-config verification and a selected-edge certificate-authenticated probe.
- [ ] 6.6 Roll out only to immutable eligible snapshots in cluster/inventory/OS/sshd/risk-class waves. Exclude hypervisors, control planes, appliances, root targets, unsupported layouts, unmanaged CA conflicts, and maintenance-held systems unless a separate higher-risk policy approves them.
- [ ] 6.7 Expose **Connect with SSH** only from current readiness and pass deployed browser -> web-ng -> core -> gateway -> selected agent -> target proofs with user/run attribution.

## 7. Child changes: Proxmox identity and terminal console

- [ ] 7.1 Create and approve `scope-proxmox-provider-identities`; make virtualization refs immutable-provider-instance scoped, distinguish them from Device integration IDs, migrate unique Farm/Tonka rows, and quarantine collisions before console use.
- [ ] 7.2 Verify online/offline topology and same-name persistence for both clusters without overwriting records or targeting Tonka's offline `pve01`.
- [ ] 7.3 Create and approve `add-proxmox-terminal-console` after identity migration.
- [ ] 7.4 Resolve guest -> parent PVE targets from trusted relations, require explicit least-privilege `console_access` rules, keep inventory credentials non-qualifying, restrict PVE endpoint/path egress, and issue only session-scoped provider grants.
- [ ] 7.5 Converge PVE and LXC `termproxy` on the generic broker's atomic attach, authorization, authenticated return route, lifecycle, recording policy, timeout, revocation, and reaper guarantees.
- [ ] 7.6 Expose ready PVE/LXC actions and pass deployed live terminal proofs with identity ambiguity, wrong node/VMID, trust, credential, route-loss, and cleanup denial cases.

## 8. Existing/separate graphical protocol owners

- [ ] 8.1 Create and separately approve `add-proxmox-qemu-graphical-console` with an RFB dependency/license/SBOM decision, threat model, PVE TLS/path binding, parser fuzzing, media/input quotas, credential disposal, exact provider fixture, and deployed graphical proof. Keep QEMU unavailable beforehand.
- [ ] 8.2 Finish the remaining adapter, helper, launch, trusted-target, and deployed proof tasks only in existing `add-remote-access-desktop-rdp`; bind the controlled target's exact FQDN/SAN/CA and NLA-only policy before RDP becomes ready.
- [ ] 8.3 Update `expand-remote-access-teleport-parity` after each child lands rather than duplicating parity ownership here.

## 9. Per-child rollout and handoff

- [ ] 9.1 For each child, define an independent demo go/no-go table, immutable build/config/evidence identifiers, canary, rollback, and sanitized acceptance record.
- [ ] 9.2 Keep secure-off Helm defaults and enable only a protocol/target combination with current deployed evidence.
- [ ] 9.3 Run the child-appropriate Go, Rust, Elixir, JS, Bazel, Ansible, OpenSpec, browser, and live-environment quality gates.
- [ ] 9.4 Roll approved builds/config to `demo` only after their child approval, wait for `Synced|Healthy|Succeeded`, re-run the exact acceptance matrix, and document revocation/offboarding/rollback.
