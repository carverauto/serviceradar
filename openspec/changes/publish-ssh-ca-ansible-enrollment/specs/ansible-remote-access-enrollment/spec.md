## ADDED Requirements

### Requirement: Public collection provides AWX-discoverable enrollment workflows
ServiceRadar SHALL publish an Apache-2.0 Ansible collection-style repository containing reusable SSH user-CA roles and separate root AWX-discoverable direct and integrated wrappers for read-only preflight, staged enrollment/rotation, fresh-connection verification/commit, and absent/offboarding. The content SHALL use typed non-secret inputs and Ansible built-ins, and MUST NOT contain or accept a deployment CA private key, callback grant, user/general API token, machine credential, or signer configuration as repository data.

#### Scenario: Operator imports a reviewed revision
- **WHEN** an operator binds an immutable reviewed repository revision and content hash to AWX and the ServiceRadar catalog
- **THEN** all four root workflows are discoverable with documented variables, callback declarations, supported platforms, and check-mode behavior

#### Scenario: Public repository is inspected
- **WHEN** a user clones the repository or downloads its release artifact
- **THEN** it contains only reusable logic and non-secret examples and no deployment-specific secret or private CA material

#### Scenario: Operator uses direct mode
- **WHEN** an operator-managed controller invokes a direct wrapper with per-host public CA/fingerprint and existing-account/principal inputs
- **THEN** the role applies the same host safety controls without a callback and makes no ServiceRadar authorization, audit, canonical-identity, or readiness claim

#### Scenario: Integrated job attempts direct fallback
- **WHEN** a ServiceRadar-bound integrated wrapper lacks its callback tuple manifest or receives direct-mode/material override variables
- **THEN** it fails before managed-host changes and cannot switch to the direct entrypoint through inventory, survey, or `extra_vars`

### Requirement: Enrollment validates supported targets before mutation
The role SHALL initially support Ubuntu 22.04/24.04, Debian 12, and Rocky Linux 9 with pinned distribution OpenSSH packages and one non-socket-activated systemd ssh/sshd instance. Integrated mode SHALL support only the OpenSSH Ansible connection plugin with an approved SSH machine-credential reference. Preflight SHALL validate platform/OpenSSH/init/layout, connection/credential mode, SELinux/FIPS compatibility, safe nonsymlink parents/paths, effective existing CA/principal/Match policy, requested non-root accounts, public keys/SHA256 fingerprints, and opaque principals before changing root-owned files. Root, UID 0, login-disabled/unsupported accounts, multiple/socket-activated instances, unknown init/config/include/Match layouts, unsupported credentials/connections, and higher-risk targets without separate policy MUST fail closed.

#### Scenario: Supported target passes preflight
- **WHEN** a supported host has an unambiguous include layout, existing requested account, valid public keys/fingerprints, safe target-specific principals, and no unmanaged CA conflict
- **THEN** preflight reports it eligible without changing files or reloading sshd

#### Scenario: Input or layout is unsafe
- **WHEN** the platform/layout is unsupported or input contains root/UID0, a missing/login-disabled account, unsafe parent/symlink, path traversal, newline, control character, principal option/whitespace, private-key marker, FIPS-incompatible/invalid key, fingerprint mismatch, or conflicting key ID
- **THEN** preflight fails before any root-owned file changes

#### Scenario: Existing organization policy conflicts
- **WHEN** effective sshd configuration uses a different `TrustedUserCAKeys` or `AuthorizedPrincipalsFile` policy not owned by the role
- **THEN** preflight reports an operator-visible conflict and does not replace or merge the unmanaged policy implicitly

### Requirement: Role installs public trust with target-specific principals
The role SHALL manage only a validated public user-CA bundle, an isolated sshd drop-in, and explicit principal files for existing non-root local accounts. Every principal SHALL be opaque and selected from immutable `(controller_id, inventory_id, awx_host_id, canonical_device_uid)` target identity. Exact play-host and granted-target tuple sets SHALL match before any host task. Hostname, IP, facts, inventory variables, surveys, and ordinary `extra_vars` MUST NOT select or relabel a mapping. The role SHALL preserve PAM, LDAP, passwords, sudo, local-account state, host keys, and unrelated sshd/session policy.

#### Scenario: Public trust is enrolled
- **WHEN** an eligible host receives its validated public CA set and target-keyed account/principal mapping
- **THEN** the role installs only its owned public trust and principal files and effective sshd policy authorizes those principals for the existing mapped accounts

#### Scenario: Principal is reused on another target
- **WHEN** a certificate bearing one host's opaque principal is presented to another enrolled host
- **THEN** that host's distinct principal file does not authorize it

#### Scenario: Play host or mapping is substituted
- **WHEN** the play host set differs from the immutable granted tuple set or an input attempts to relabel one tuple as another
- **THEN** the entire child fails with zero managed-host changes and no hostname/IP fallback

### Requirement: Enrollment is transactional and proves effective configuration
The role SHALL run baseline `sshd -t`; reject unsafe parents/symlinks; snapshot prior absence/content/owner/group/mode/ACL/SELinux context of role-owned paths; validate a complete candidate config/tree; install atomically; run live `sshd -t` and account/Match-aware `sshd -T -C user=...,host=...,addr=...`; and reload only, never restart. Each mutation SHALL bind the authoritative target, stage transaction/run ID, prior snapshot generation/digest, and canonical rendered-policy digest. Only one pending mutation may exist per target. Before reload the role SHALL atomically arm a bounded credential-free persistent systemd rollback timer plus boot-recovery marker that survives reboot/systemd restart and restores/validates the same uncommitted generation. The stage job SHALL preserve its controlling connection. A separate AWX verification job SHALL use the exact snapshotted SSH machine-credential reference and record a new-session proof with the same bindings. Commit SHALL lock and atomically compare proof, marker, generation, and current live-policy digest before disarming/removing rollback. Stale, duplicate, mismatched, concurrent, or timer-expiry-racing verify/commit SHALL fail closed. Failed/unstarted verification SHALL allow automatic rollback. Failed rescue SHALL emit machine-readable `critical_manual_recovery` and abort; the AWX-targeting prerequisite SHALL durably quarantine/exclude that host from later ServiceRadar waves.

#### Scenario: Candidate is valid
- **WHEN** rendered trust and principal policy passes candidate and installed effective checks
- **THEN** files are installed atomically, sshd is reloaded only if effective state changed, the generation-bound reboot-safe rollback guard remains armed, and a separate bound verification job proves a fresh automation connection before atomic commit

#### Scenario: Commit races rollback or is stale
- **WHEN** commit has a stale transaction/generation/policy digest, another mutation is pending, the live policy changed, or rollback expiry wins the transaction lock
- **THEN** commit cannot disarm rollback or delete the snapshot and the target remains failed closed for reconciliation

#### Scenario: Host reboots while staged
- **WHEN** the host or systemd restarts before matching verification and commit
- **THEN** the persistent timer or boot-recovery marker restores the same uncommitted generation rather than silently accepting staged policy

#### Scenario: Validation or reconnect fails
- **WHEN** candidate/installed validation, reload, or fresh connection proof fails
- **THEN** immediate rescue or timer expiry restores prior absence/content/metadata/SELinux state, leaves sshd valid and available, and reports a failed host without secret data

#### Scenario: Rescue cannot restore service
- **WHEN** rollback cannot revalidate/reload the prior state or prove original-credential reconnection
- **THEN** the role emits `critical_manual_recovery` and aborts, and the AWX-targeting control plane durably quarantines the target so no later fleet wave targets it automatically

#### Scenario: Same state is applied twice
- **WHEN** enrollment is rerun with the same public keys, fingerprints, accounts, and principals
- **THEN** the second run reports no changes and does not reload sshd

### Requirement: Public CA rotation uses an explicit overlap set
The role SHALL support overlap installation containing old and new validated public CA keys. For integrated wrappers, ServiceRadar SHALL independently prove a selected-edge certificate login signed by the new key and bind that fresh proof to target, CA key/fingerprint, principal policy version, and route; a separate retirement job SHALL require `devices.remote_access.ssh.ca_trust.retire`, that proof, and an explicit desired set. For direct wrappers, the operator controller SHALL separately authenticate with a controller-owned SSH credential containing a new-CA-signed certificate and record a target/transaction/policy/fingerprint-bound proof; retirement SHALL require that proof, the controller's own authorization/approval, and explicit confirmation naming retiring and remaining fingerprints. Direct confirmation MUST NOT satisfy an integrated proof or permission gate.

#### Scenario: New CA enters overlap
- **WHEN** the desired set contains both the active old key and a validated new key
- **THEN** both keys are trusted while target-specific principal restrictions remain unchanged

#### Scenario: Old CA is retired
- **WHEN** a separately authorized retirement run has a current matching new-CA edge-login proof and a reviewed desired set containing only the new key
- **THEN** the old public key is removed, effective configuration is revalidated, and certificates from the retired CA are no longer trusted

#### Scenario: New CA has no independent login proof
- **WHEN** overlap is installed but no current matching selected-edge certificate-login proof exists
- **THEN** the retirement job makes no change even if its desired set omits the old key

#### Scenario: Direct operator retires an old CA
- **WHEN** an authorized direct-mode operator has a matching separate new-CA credential-login proof and explicitly confirms the retiring and remaining fingerprints
- **THEN** the direct retirement wrapper uses the same staged transaction safety without claiming or requiring ServiceRadar RBAC

### Requirement: Check, verify, and absent workflows are safe
Check mode SHALL report the exact planned role-owned changes without reloading sshd. Verification SHALL evaluate effective CA/principal configuration through a separate fresh SSH-machine-credential job, and commit SHALL cancel the armed rollback only after that proof. Integrated absent/offboarding SHALL additionally require `devices.remote_access.ssh.ca_trust.remove`; direct absent/offboarding SHALL require the operator controller's own authorization/approval plus explicit destructive confirmation. Both modes SHALL remove only role-owned trust/principal configuration, validate and conditionally reload sshd, use the same generation-bound guard/verify/commit sequence, and leave accounts and unmanaged policy intact. Bundle-read or ordinary integrated launch permission alone MUST NOT authorize retirement or removal, and direct confirmation MUST NOT bypass an integrated permission gate.

#### Scenario: Operator runs check mode
- **WHEN** an enrollment or removal wrapper is launched in native Ansible check mode
- **THEN** it reports planned role-owned changes without writing files or reloading sshd

#### Scenario: Operator verifies enrollment
- **WHEN** the verify wrapper evaluates an enrolled account
- **THEN** it establishes a new bound SSH session, confirms expected fingerprints and account-aware effective principal/trust paths, and permits the separate commit wrapper to cancel the rollback timer

#### Scenario: Operator offboards a host
- **WHEN** an actor with the separate removal permission runs the absent wrapper on an enrolled host
- **THEN** only role-owned files are removed and sshd remains valid/reachable with local accounts and unrelated policy unchanged

#### Scenario: Bundle reader requests removal
- **WHEN** an actor has `ansible.runs.launch` and `devices.remote_access.ssh.ca_bundle.read` but lacks `devices.remote_access.ssh.ca_trust.remove`
- **THEN** ServiceRadar does not launch absent/offboarding

#### Scenario: Direct operator requests removal
- **WHEN** the operator controller authorizes a direct absent run and the operator explicitly confirms the exact target and role-owned policy digest to remove
- **THEN** the direct wrapper uses staged rollback and fresh-connection commit without asserting ServiceRadar RBAC

### Requirement: Callback helper consumes a bounded public-bundle contract
For integrated launches, the public content SHALL provide a controller-only helper for the separately implemented `remote_access.ssh_ca.bundle.read` action. Execution SHALL require initiating-principal permissions `ansible.runs.launch` and `devices.remote_access.ssh.ca_bundle.read`, exact target policy/approval, and the reviewed immutable project/template/custom-credential/revision binding. The helper SHALL call the server-selected HTTPS endpoint once from the AWX execution environment with `use_proxy: false`, strict TLS/no redirects, bounded timeout, content/schema/policy/fingerprint validation, and exact tuple/play-host set equality. The server endpoint and reviewed EE egress proxy SHALL enforce a small pre-download response cap; the helper SHALL additionally reject oversized content after receipt. It SHALL use `no_log`, SHALL NOT cache facts, and MUST NOT persist or send the callback grant/fleet response to managed hosts.

The bearer is necessarily transient inside the reviewed AWX credential-decryption path, EE code, and local `ansible.builtin.uri` invocation. Persistence, logging, fact/artifact storage, forwarding, relaunch reuse, and managed-host exposure are forbidden; terminal/ambiguous jobs delete/detach the ephemeral credential and revoke the grant.

#### Scenario: Authorized callback response matches the job
- **WHEN** the separately authorized custom credential returns a valid public bundle and mappings keyed by the exact `(controller, inventory, AWX host ID, canonical device UID)` tuples for the play host set
- **THEN** the helper selects only each host's internal public-key and principal configuration by authoritative target identity and passes that data to the enrollment role

#### Scenario: Target mapping is ambiguous or substituted
- **WHEN** the response/play set is missing/extra/duplicate, mismatches any immutable tuple, or hostname/IP/fact/survey/extra-var input attempts substitution
- **THEN** the helper fails the whole child before enrollment with zero host changes and no fallback

#### Scenario: Callback credential is absent or unsafe
- **WHEN** a caller supplies an ordinary extra-var/survey token, general API key, user access token, arbitrary endpoint, redirect, invalid TLS identity, or malformed/oversized response
- **THEN** the helper rejects it without contacting managed hosts or exposing credential data in output, facts, events, or artifacts

#### Scenario: Job is relaunched or credential restored
- **WHEN** AWX relaunch/copy or a restored backup attempts to reuse a prior ephemeral credential
- **THEN** the revoked grant is unusable and a newly authorized ServiceRadar child is required

### Requirement: Public content is continuously tested and immutably released
Forgejo actions/runners, Molecule/OS images, and Python/Ansible/lint dependencies SHALL be pinned and reviewed. CI SHALL run yamllint, ansible-lint, syntax checks for every root wrapper, and real-sshd systemd-capable Molecule tests across the supported matrix. Tests SHALL cover direct/integrated isolation and authorization, install, check/idempotence, tuple substitution, overlap/proof-gated retirement, root/account/SELinux/FIPS/layout/credential rejection, conflicts, verification/removal permissions, reload, reboot/systemd-restart guard survival, stale/concurrent/timer-expiry commit races, separate original-credential verification/commit, full-metadata rollback, and machine-readable failed-rescue abort. Test CA private keys SHALL be generated ephemerally, never committed/cached/uploaded/logged/retained. Production import SHALL pin a reviewed immutable commit/tag, content hash, and verifiable dependency/image provenance rather than a moving branch.

#### Scenario: Pull request changes enrollment behavior
- **WHEN** a pull request modifies roles, wrappers, variables, callback schema metadata, or supported platforms
- **THEN** all lint, syntax, distro, idempotence, rotation, removal, and rollback gates must pass before merge

#### Scenario: AWX imports content
- **WHEN** the public content is approved for a later AWX binding
- **THEN** the binding records the reviewed commit/content hash and does not execute an unreviewed moving branch
