# Change: Publish SSH CA Ansible enrollment content

## Why

ServiceRadar needs a public, reusable way to enroll Linux SSH targets without publishing a deployment CA, copying the CA private key, or teaching every operator to build one-off sshd automation. The existing seed playbook is not collection-ready and does not provide rotation overlap, effective-configuration verification, transactional rollback, offboarding, or supported-platform CI.

This child implements only the public Ansible content and the immutable metadata needed to import and bind it. Secure callback-grant issuance, AWX targeting, live controller configuration, host mutation, and ServiceRadar readiness are separately approved prerequisites or follow-on changes.

## What Changes

- Publish an Apache-2.0 Ansible collection-style repository with reusable roles, root AWX-discoverable wrappers, typed defaults, non-secret examples, runtime metadata, documentation, and a changelog.
- Provide preflight, staged enroll/rotate, fresh-connection verify/commit, and absent/offboarding workflows for Ubuntu 22.04/24.04, Debian 12, and Rocky Linux 9.
- Install only public SSH user CA keys and target-specific opaque principal mappings selected from immutable `(controller, inventory, AWX host ID, canonical device UID)` identity. Preserve existing PAM, local-account, LDAP, sudo, and session policy; reject root/UID 0 and unsupported privileged/login-disabled accounts in default-risk enrollment.
- Support two-phase public CA rotation: overlap installation, independent new-CA certificate-login proof, then a separately authorized retirement job. Include fingerprint validation, check mode, idempotence, baseline/candidate/effective `sshd -t`/`sshd -T -C` validation, a reboot-safe transaction-bound host rollback guard, separate original-credential verification/commit jobs, atomic rescue, and full role-owned metadata restoration.
- Add a controller-only callback helper that consumes the separately implemented `remote_access.ssh_ca.bundle.read` contract with Ansible built-ins. It enforces exact play-host/target equality and never forwards the grant or fleet-wide mapping to a managed host.
- Publish separate direct-input wrappers for operator-managed controllers. ServiceRadar catalog bindings use only integrated wrappers, which require the callback manifest and cannot be downgraded to direct inputs.
- Declare the callback action and response schema in reviewed catalog metadata so ServiceRadar/AWX can bind an immutable repository revision and content hash.
- Add pinned Forgejo lint/syntax/dependency/image gates and real-sshd Molecule coverage for supported distributions, SELinux/FIPS/layout handling, rotation, invalid input, idempotence, removal, check mode, rollback, and ephemeral uncommitted test-CA generation.
- Publish the work on a feature branch and open a public repository pull request; pin an approved commit before later AWX import.

## Impact

- Affected specs: `ansible-remote-access-enrollment` (new)
- Affected repository: `/Users/mfreeman/src/serviceradar-ansible-remote-access`
- Import prerequisites: reviewed immutable SCM revision/content hash, exact AWX project/template/custom-credential binding, and ServiceRadar catalog binding
- External dependencies: approved `add-automation-callback-grants` and `harden-ansible-awx-targeting`; initiating principal holds `ansible.runs.launch` plus `devices.remote_access.ssh.ca_bundle.read`; exact target policy/approval; separate `devices.remote_access.ssh.ca_trust.retire` and `devices.remote_access.ssh.ca_trust.remove` permissions for destructive operations
- Supersession: this bounded child solely owns the public Ansible enrollment capability and replaces the draft Ansible-enrollment delta in the unmerged program discovery record
- Explicitly out of scope: ServiceRadar callback/API code, ServiceRadar CLI changes, CA signing/private-key custody, live AWX mutation, target enrollment, fleet rollout, remote-access readiness, and demo deployment
