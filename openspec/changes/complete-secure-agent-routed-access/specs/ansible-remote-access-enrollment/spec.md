## ADDED Requirements

### Requirement: Public reusable SSH-CA enrollment content
ServiceRadar SHALL publish reusable Ansible content that installs, verifies, rotates, and removes the public ServiceRadar SSH user CA and explicit local-account principal policy on supported Linux hosts. The content MUST NOT accept, copy, render, or persist the SSH CA private key.

#### Scenario: Operator imports the public repository
- **WHEN** an operator registers a published `serviceradar-ansible` revision in ServiceRadar/AWX
- **THEN** the catalog exposes documented preflight, enrollment/rotation, verification, and rollback playbooks with non-secret typed variables

#### Scenario: Enrollment is run twice
- **WHEN** the same public CA and principal policy are applied to an already-enrolled host
- **THEN** the second run is idempotent and does not reload sshd or report unrelated changes

#### Scenario: Candidate sshd configuration is invalid
- **WHEN** the playbook's isolated drop-in or principal files fail validation
- **THEN** the role restores the prior configuration, does not leave sshd unavailable, and reports a per-host failed result without exposing sensitive data

#### Scenario: Public repository is inspected
- **WHEN** a user clones the public Ansible repository
- **THEN** it contains reusable role/playbook logic and non-secret examples but no deployment CA, API token, machine credential, signer configuration, or private key

#### Scenario: Unsafe account or principal input
- **WHEN** an input contains path traversal, newlines, control characters, SSH principal options, a missing local account, or private-key material
- **THEN** preflight rejects the input before any root-owned file changes

#### Scenario: Existing organization CA conflicts
- **WHEN** effective sshd configuration already uses a different TrustedUserCAKeys path that the role does not own
- **THEN** the role fails safely with an operator-visible conflict instead of silently replacing the existing trust policy

### Requirement: Integrated enrollment retrieves server-owned public trust with a delegated grant
For a ServiceRadar-launched enrollment job, the control plane SHALL require the logged-in user's current profile to grant both `ansible.runs.launch` and the permission mapped to `remote_access.ssh_ca.bundle.read`, plus target policy and required approval. It SHALL mint a pending short-lived delegated automation callback grant only after that authorization. The AWX execution environment SHALL use the activated grant once to retrieve the server-owned public SSH CA bundle and immutable target-keyed principal mapping. The integrated workflow MUST NOT forward the user's normal access token or require an operator-created general ServiceRadar API key or ServiceRadar CLI on AWX or managed targets.

#### Scenario: Authorized integrated launch
- **WHEN** an actor with Ansible launch and remote-access CA distribution permissions confirms enrollment targets
- **THEN** ServiceRadar launches AWX using its existing brokered controller credential and supplies a separate callback grant bound to that actor, run, playbook, target snapshot, named CA-bundle action, TTL, and request budget

#### Scenario: Profile has only one required permission
- **WHEN** the logged-in user's ServiceRadar profile grants only Ansible launch or only remote-access CA-bundle retrieval
- **THEN** ServiceRadar identifies the missing permission and does not create or dispatch the AWX job

#### Scenario: Browser attempts CA substitution
- **WHEN** a browser or API caller supplies a different callback URL/action/token, CA key, fingerprint, policy version, or principal mapping
- **THEN** the control plane rejects the override and authorizes only the server-selected callback action and response

#### Scenario: Managed host runs the role
- **WHEN** AWX applies the enrollment role
- **THEN** the callback executes once on the AWX controller/execution environment, the host receives only public CA/principal files through Ansible's normal machine connection, and neither the callback token nor `serviceradar-cli` reaches the host

#### Scenario: One target's mapping is applied to another
- **WHEN** automation attempts to substitute or relabel a target-specific principal mapping inside a fleet child job
- **THEN** callback schema validation or post-apply verification fails closed and records the affected target without enabling cross-target certificate use

### Requirement: External public-bundle retrieval is narrowly delegated
ServiceRadar SHALL provide CLI/API workflows for an authenticated operator to mint, inspect, and revoke named-action automation callback grants and export the public SSH CA trust bundle. Optional unattended external retrieval SHALL use an owned fixed-ceiling service principal or workload identity limited to one tenant, reviewed catalog/template revisions, the public-bundle action, an explicit target ceiling, TTL/budget, expiry, rotation, and disable controls. It MUST NOT use a general-purpose platform API token or wildcard/self-expanding authority.

#### Scenario: Operator exports a bundle interactively
- **WHEN** an authorized operator uses the ServiceRadar CLI or API to export the trust bundle
- **THEN** ServiceRadar mints or internally uses a named-action grant and the output contains only public keys, key IDs/fingerprints, policy version, and an Ansible-compatible representation

#### Scenario: External AWX retrieves automatically
- **WHEN** an operator chooses API retrieval outside the integrated launch path
- **THEN** documentation requires a short-lived named-action grant or a workload-authenticated fixed-ceiling service principal that can mint only that grant, and prohibits passing either credential to managed hosts

### Requirement: Ansible enrollment preserves target account policy
The enrollment role SHALL manage only SSH user-CA trust and explicit certificate principals while preserving each target's existing local account, PAM, LDAP, sudo, and session policy. It SHALL validate the intended local accounts before enabling their principal files.

#### Scenario: Demo mfreeman principal
- **WHEN** the demo policy maps the certificate principal `mfreeman` to the existing local account `mfreeman`
- **THEN** the role verifies that account, installs only the public CA/principal policy, and leaves the account's PAM and sudo behavior unchanged

#### Scenario: Principal references a missing local account
- **WHEN** enrollment requests a principal mapping for a local account that does not exist
- **THEN** preflight fails for that host before sshd configuration changes

### Requirement: Fleet launches are collision safe across inventories
ServiceRadar SHALL bind an Ansible enrollment target to canonical device UID, controller ID, inventory ID, AWX host ID, inventory host name, and current `ansible_host`. A fleet request spanning inventories SHALL be partitioned by controller, inventory, and job template, and MUST NOT use an unqualified global display-hostname limit.

#### Scenario: Duplicate hostname in farm01 and tonka01
- **WHEN** `farm01` and `tonka01` each contain a Linux host with the same display hostname but different inventory identity and IP address
- **THEN** ServiceRadar launches and correlates each host within its own authoritative inventory partition and displays both IP/cluster contexts for confirmation

#### Scenario: AWX host link drifts before launch
- **WHEN** the current AWX host ID, inventory, host name, or `ansible_host` no longer matches the stored device target snapshot
- **THEN** ServiceRadar rejects that target as drifted and does not fall back to matching by hostname

#### Scenario: Selection spans two inventories
- **WHEN** an authorized operator selects eligible hosts from both Proxmox clusters
- **THEN** ServiceRadar creates one parent operation and separate AWX child jobs per controller/inventory/template while retaining per-device results

#### Scenario: Limit would be empty
- **WHEN** any child partition has no validated inventory host names or would produce an empty AWX limit
- **THEN** ServiceRadar rejects the child and MUST NOT omit the limit or run the job template against its full inventory

#### Scenario: Job template inventory is incompatible
- **WHEN** a target partition's inventory differs from a template's fixed inventory and the template does not allow an inventory prompt
- **THEN** ServiceRadar rejects the launch instead of relying on the template's default inventory

### Requirement: AWX source identity is not hostname derived
ServiceRadar SHALL identify AWX hosts by controller ID, inventory ID, and AWX host ID. It SHALL preserve multiple AWX inventory memberships without treating a duplicate hostname as a strong canonical-device identifier.

#### Scenario: Same pve01 name in both clusters
- **WHEN** `farm01` and `tonka01` each emit an AWX host named `pve01`
- **THEN** the hosts retain distinct integration identities and cannot overmerge solely because their display names match

#### Scenario: Device belongs to multiple inventories
- **WHEN** one canonical device legitimately has more than one AWX inventory membership
- **THEN** ServiceRadar retains each membership and requires the launch to select the membership compatible with the job template

### Requirement: Ansible run targets and events retain source identity
Every Ansible run target and per-host result SHALL retain controller, inventory, AWX host ID/name, `ansible_host`, canonical device UID, child AWX job ID, and launch snapshot. Target creation or event correlation ambiguity MUST fail visibly rather than silently dropping a target.

#### Scenario: Duplicate runner host strings
- **WHEN** two child jobs report the same runner hostname for different inventory host IDs
- **THEN** ServiceRadar correlates each event inside its child job/inventory target identity and preserves both results

#### Scenario: Target row cannot be created
- **WHEN** a selected target conflicts with an existing run-target identity or fails validation
- **THEN** the parent launch stops before AWX execution and reports the affected device instead of ignoring the create error

### Requirement: Fleet enrollment preserves human audit and explicit check mode
The system SHALL record the human actor and exact target/inventory/limit/check-mode/playbook snapshot for enrollment launches. Dry run SHALL use AWX's explicit check-mode/job-type support or a dedicated bound check template and MUST NOT be simulated by untrusted extra variables.

#### Scenario: Human launches from device inventory
- **WHEN** an authorized user confirms a fleet enrollment
- **THEN** audit records that user, the source request, every target identity, actual non-empty limits/inventories, playbook revision/hash, check mode, and resulting AWX job IDs

#### Scenario: Operator requests dry run
- **WHEN** the selected template cannot execute an explicit check-mode job and no approved check template is bound
- **THEN** ServiceRadar reports dry run unavailable and does not launch a normal mutating job

### Requirement: Fleet enrollment uses preflight, canary, and verification gates
ServiceRadar SHALL roll out SSH-CA enrollment through read-only preflight, Ansible check mode, at least one canary per inventory/cluster, and bounded waves. A host SHALL become remote-access ready only after both Ansible effective-config verification and a certificate-authenticated probe through its selected ServiceRadar edge route succeed.

Fleet selection SHALL use an explicit immutable target snapshot. Discovery, a Linux label, Proxmox membership, or AWX inventory presence alone MUST NOT authorize enrollment. Default-risk eligibility requires one unambiguous canonical device and AWX membership, exact current address, supported OS/sshd layout, validated non-root account, authorized machine/become credential, selected reachable edge route, no unmanaged CA conflict/exclusion/maintenance hold, and successful preflight. Hypervisors, Kubernetes control planes, AWX, ServiceRadar, CNPG, identity/storage/control-plane systems, network/security appliances, and root target accounts SHALL be excluded unless a separate higher-risk policy and approval explicitly selects them.

#### Scenario: Canary fails in one cluster
- **WHEN** the `tonka01` canary fails validation, reload, or certificate-authenticated edge probing
- **THEN** the `tonka01` rollout stops without blocking already-proved `farm01` targets or widening the target limit

#### Scenario: AWX reports success but edge proof fails
- **WHEN** the enrollment playbook verifies sshd locally but the selected ServiceRadar agent cannot complete certificate-authenticated SSH
- **THEN** the host remains remote-access unready with a sanitized verification reason

#### Scenario: Wave has mixed results
- **WHEN** a bounded fleet wave succeeds on some hosts and fails or is unreachable on others
- **THEN** ServiceRadar records per-device outcomes, does not mark failed hosts ready, and permits a scoped retry or rollback without retargeting successful hosts by hostname

#### Scenario: Discovered Linux infrastructure is excluded
- **WHEN** a discovered Linux host is a PVE node, control-plane system, appliance, root-only target, unsupported sshd layout, or has an unmanaged CA conflict
- **THEN** preflight reports a stable exclusion reason and makes no change unless an authorized higher-risk policy separately approves that exact host
