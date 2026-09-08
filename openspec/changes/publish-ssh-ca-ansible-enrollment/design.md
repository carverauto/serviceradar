## Context

The public repository must be useful both from an operator-managed Ansible controller and from ServiceRadar-launched AWX jobs. Only public trust material belongs in the role. A ServiceRadar-integrated job may retrieve that material through a short-lived callback grant, but the grant is an AWX execution-environment secret and is never a managed-host variable. Direct/operator-managed and ServiceRadar-integrated entrypoints are separate security modes, not a runtime fallback.

## Goals / Non-Goals

### Goals

- Ship reusable, tested SSH user-CA enrollment content with safe rotation and removal.
- Make playbooks visible at repository root for predictable AWX project discovery while retaining reusable collection roles.
- Keep principal authorization target-specific and fail closed on identity or existing-CA ambiguity.
- Define a narrow callback consumer compatible with the separately approved callback-grant contract.
- Provide reproducible public-repository quality and release gates.

### Non-Goals

- Implement callback grants, ServiceRadar permissions, APIs, or CLI commands.
- Configure AWX projects, credentials, inventories, templates, or execution environments.
- Generate, store, publish, or distribute an SSH CA private key.
- Mutate demo or production hosts or claim that a host is remote-access ready.
- Manage passwords, sudo, PAM, LDAP, local-account creation, host keys, or SSH server policy unrelated to user-certificate trust.
- Enroll `root`, UID 0, login-disabled/unsupported accounts, PVE/hypervisors, or other higher-risk control-plane targets through the default-risk workflow.

## Decisions

### Decision: Collection-compatible layout with root AWX wrappers

The public repository will include `galaxy.yml`, `meta/runtime.yml`, `roles/remote_access_ssh_ca`, a controller-only callback helper role, playbooks under `playbooks/`, and thin root wrappers for preflight, staged enroll/rotate, fresh-connection verify/commit, and absent/offboarding. Root wrappers use static playbook imports and contain no deployment values. Role modules use fully qualified `ansible.builtin` names and avoid third-party runtime collections.

The repository also includes Apache-2.0 licensing, README/operator documentation, typed defaults, non-secret examples, a changelog, Molecule scenarios, yamllint/ansible-lint configuration, and Forgejo CI. An immutable reviewed commit and content hash are the import unit; a moving branch is not an approved automation binding.

### Decision: Public material and target-keyed policy only

The enrollment role accepts a non-empty list of OpenSSH public user-CA keys with expected SHA256 fingerprints and a mapping for the immutable current target containing validated existing non-root local accounts and opaque target-specific principals. It rejects `root`, UID 0, login-disabled/unsupported shells, higher-risk targets lacking separate policy, private-key markers, unknown/FIPS-incompatible key types, fingerprint mismatch, duplicate/conflicting key IDs, empty trust sets in present state, unsafe account names, path traversal, newlines, control characters, whitespace/options in principals, and missing accounts.

The callback response is keyed by immutable `(controller_id, inventory_id, awx_host_id, canonical_device_uid)` tuples and also carries the snapshotted inventory host name/address only as verified launch correlation. Before any managed-host task, the integrated helper verifies set equality between `ansible_play_hosts_all`, the granted tuples, and the exact child launch manifest. It derives each host's values from the server-returned manifest; hostname, IP, facts, inventory/group/host variables, surveys, and ordinary `extra_vars` cannot select, relabel, or replace a mapping. Any missing, extra, duplicate, or substituted target fails the whole child with zero host changes. The fleet response remains on the reviewed execution environment.

Direct/operator-managed wrappers never accept a callback URL or grant. They accept explicit per-inventory-host public CA keys/fingerprints and existing-account/principal mappings under the operator controller's own authorization model, run the same host safety checks, and make no ServiceRadar authorization, audit, readiness, or canonical-identity claim. Integrated wrappers are separate static entrypoints, require the callback custom credential and tuple manifest, reject direct-input variables, and are the only wrappers eligible for the ServiceRadar catalog. A survey, inventory variable, or `extra_vars` value cannot switch an integrated job into direct mode.

### Decision: Isolated ownership and transactional sshd changes

The role owns one CA bundle, one sshd drop-in, and its principal directory under documented fixed paths. Preflight discovers the platform service name and sshd binary, confirms the supported drop-in/include layout, reads effective configuration, validates local accounts, and fails on an unmanaged `TrustedUserCAKeys` or `AuthorizedPrincipalsFile` conflict. It does not rewrite an existing organization CA policy.

Before mutation, the role runs baseline `sshd -t`; lstat-checks owned paths and safe parents; rejects symlinks; and snapshots prior absence/content, owner/group, mode, ACL, and SELinux context. It builds a complete candidate config/tree whose includes point at staged candidate files, validates it, installs atomically, reruns live `sshd -t`, and evaluates every relevant account/`Match` context with `sshd -T -C user=...,host=...,addr=...`.

Each mutation is a generation-bound transaction. The protected marker, snapshot, persistent rollback timer/boot-recovery unit, verification result, and commit bind the authoritative target identity, stage transaction/run ID, prior snapshot generation/digest, and canonical rendered-policy digest. Only one pending mutation may exist per target. Before reload the role atomically creates that state and arms a role-owned absolute-deadline systemd timer with persistent catch-up plus a boot recovery marker; neither contains credentials, and reboot/systemd restart cannot silently discard rollback. Expiry restores the full snapshot only if the same uncommitted generation remains current, validates it, and reloads the prior daemon. The stage job reloads only, never restarts, preserves its current control connection, and does not disarm rollback.

Fresh authentication is owned by a separate AWX verification job using the exact snapshotted controller, inventory, host, and approved SSH machine-credential reference; integrated mode rejects non-SSH connection plugins and unsupported credential modes. That new job must prove a new SSH session rather than reuse the stage job's control connection and record the same target/transaction/generation/policy digest. The commit wrapper takes the host transaction lock and atomically compares that proof, the marker, and the current live-policy digest before disarming/removing rollback state. Stale, duplicate, mismatched, concurrent, or timer-expiry-racing verify/commit attempts fail closed and cannot cancel rollback. Failure or absence of verify/commit lets the guard roll back automatically. Immediate stage/validation/reload failures restore within the current connection. If either rescue path cannot restore and validate the prior daemon, the role emits a machine-readable `critical_manual_recovery` result and aborts. The `harden-ansible-awx-targeting` child owns durable ServiceRadar quarantine and later-wave exclusion based on that result; this public content does not call a mutating ServiceRadar API.

### Decision: Explicit overlap rotation and bounded removal

Rotation is two separately authorized operations, not a single desired-set edit. The overlap job installs old and new validated public keys. In integrated mode ServiceRadar then performs an independent selected-edge certificate login signed by the new CA and records a proof bound to target, CA key ID/fingerprint, principal policy version, route, and freshness. Only a later integrated retirement job holding `devices.remote_access.ssh.ca_trust.retire` and that current proof may remove the old key. Integrated `state: absent` similarly requires `devices.remote_access.ssh.ca_trust.remove`.

Direct mode uses the operator controller's authorization/approval model instead of ServiceRadar permissions. Its new-CA verification wrapper must establish a separate SSH session using a controller-owned machine credential containing a new-CA-signed user certificate and record a controller-local proof bound to target, transaction, policy digest, and new-key fingerprint. Direct retirement requires that proof plus explicit confirmation naming the expected retiring and remaining fingerprints; direct absent requires explicit destructive confirmation and the timer/verify/commit sequence. Integrated proofs/permissions cannot be replaced by direct confirmations, and direct mode never claims ServiceRadar authorization. Both modes keep principals target-specific, remove only role-owned files, validate effective sshd configuration, and never delete unmanaged policy or change local accounts.

### Decision: Callback helper is a consumer, not an authorization boundary

The helper uses `ansible.builtin.uri` with `delegate_to: localhost`, `run_once`, `changed_when: false`, `no_log: true`, `use_proxy: false`, strict TLS verification, no redirects, bounded timeout, and exact content/schema validation. Because the built-in module cannot independently cap bytes before reading, the ServiceRadar endpoint and reviewed execution-environment egress proxy enforce the small action response limit; the helper also rejects oversized returned content after receipt. Its URL and opaque one-use grant arrive only through the separately reviewed ephemeral AWX custom credential injector. The bearer is transiently visible to the reviewed local module invocation and EE code, but must not persist in job output/events, facts/cache, artifacts, relaunch/copy inputs, support data, or managed hosts. Credential deletion/grant revocation makes backup/restore inert. Ordinary extra-vars/surveys, arbitrary URLs, general API keys, and user access tokens are rejected. The helper does not invoke curl or `serviceradar-cli`.

The catalog declares `remote_access.ssh_ca.bundle.read`, its response schema version, and the exact wrappers that consume it. Integrated execution cannot start unless the initiating principal holds `ansible.runs.launch` and `devices.remote_access.ssh.ca_bundle.read`, exact target policy/approval passes, and the immutable project/template/custom-credential/revision binding matches. Retirement and removal additionally require their separate destructive permissions. ServiceRadar permission checks, pending-to-active grant binding, replay protection, cancellation, credential lifecycle, and API behavior are dependencies owned by the callback-grants child.

### Decision: Supported-platform and behavioral test matrix

Initial support is Ubuntu 22.04/24.04, Debian 12, and Rocky Linux 9 using pinned distribution OpenSSH packages, the OpenSSH Ansible connection plugin with an approved SSH machine credential for integrated jobs, and a single non-socket-activated systemd ssh/sshd instance. Preflight preserves/restores SELinux contexts on Rocky, rejects FIPS-incompatible CA algorithms, and fails closed on socket activation, multiple instances, nonstandard configs, unsafe parent paths/symlinks, unsupported `Match`/include layouts, unsupported connection/credential modes, or unknown init systems. CI uses real sshd in pinned systemd-capable fixtures and runs yamllint, ansible-lint, syntax checks, plus Molecule coverage for clean install, second-run idempotence, check mode, overlap, integrated/direct independent-proof retirement gating, invalid inputs, conflicts, missing/root/login-disabled accounts, SELinux/FIPS/layout failure, removal, reload, reboot/systemd-restart survival, timer expiry/commit races, separate original-credential verification/commit, byte-identical+metadata rescue, and critical rescue failure.

CI actions, runner images, Molecule images, Python/Ansible dependencies, and lint/test dependencies are pinned and reviewed. Any test CA private key is generated ephemerally inside a job, never committed, uploaded, cached, or retained as an artifact. The published commit/tag records verifiable content provenance and dependency/image identifiers.

## Risks / Trade-offs

- Containerized Molecule can hide service-manager behavior. Use systemd-capable fixtures and assert effective sshd output, reload, and reconnection rather than file content alone.
- A callback bearer is visible transiently to the trusted AWX controller/EE. Keep it in the custom credential injector, mark every task/result `no_log`, prohibit fact caching/artifacts, and test that job events and relaunch data contain no credential.
- Existing sshd customization varies. The first version fails closed outside its documented include layout instead of editing arbitrary monolithic configurations.
- Removing a retired CA too early can lock out certificates signed by it. A separate permission plus fresh independent new-CA edge-login proof gates retirement.

## Migration and Rollback

1. Merge and tag the public repository after CI and security review.
2. Record the immutable commit/content hash in the later ServiceRadar/AWX binding change.
3. Run read-only preflight/check, stage overlap keys with the generation-bound reboot-safe rollback guard armed, prove a new original-credential connection in a separate job, and atomically commit the matching live policy; require the mode-appropriate independent new-CA certificate-login proof before a separately authorized retirement job.
4. Roll back a failed or uncommitted mutation automatically from the full role-owned file/metadata snapshot; emit `critical_manual_recovery` if rescue cannot prove the prior daemon, and let the targeting prerequisite durably quarantine/exclude that host.
5. Use the separately authorized absent wrapper for deliberate offboarding.
6. Revert imported content by pinning the last approved immutable repository revision; never follow a mutable branch in production.
