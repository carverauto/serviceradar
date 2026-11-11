## ADDED Requirements

### Requirement: One enrollment role and one layout
The public enrollment content SHALL provide exactly one role that writes SSH certificate trust, `remote_access_ssh_ca`, and that role SHALL write only the single on-host layout defined by the ServiceRadar enrollment capability.
The older `fleet_ssh_enroll` role and its playbook are removed from the content in the release in which the surviving role adopts its layout, with a migration note. No role in the content defaults an account name.

#### Scenario: Content lists its enrollment roles
- **WHEN** the released content is inspected
- **THEN** `remote_access_ssh_ca` is the only role that writes `TrustedUserCAKeys` or an authorized-principals file

### Requirement: Pre-existing layouts are adopted, not rejected
The role's enroll operation SHALL convert a host that carries a recognized earlier layout into the single layout inside one transaction, and SHALL NOT fail such a host as an unmanaged conflict.
Adoption needs no separate operation, wrapper or operator choice: preflight reports that the host will be adopted, and check mode shows the plan.
The recognized earlier layouts are the `fleet_ssh_enroll` layout and the layout the product documentation described before this change. A layout is recognized only when its files are at the known paths and every CA key it trusts has a fingerprint present in the bundle's CA keys. Adoption snapshots the earlier files, stages the single layout from the bundle, activates it, and removes the earlier drop-in, CA file and principals files only after the role's own verification succeeds; a failure restores the snapshot. The result names which layout was adopted. A host that trusts a CA not present in the bundle, or that sets the same directives from a place the role does not recognize, is still refused, with the reason `unmanaged_ca_conflict`.

#### Scenario: Host enrolled by the older role
- **GIVEN** a host carrying the `fleet_ssh_enroll` layout whose CA fingerprint is in the bundle
- **WHEN** the role enrolls the host
- **THEN** the host ends with the single layout only
- **AND** the result reports the adopted layout

#### Scenario: Adoption fails midway
- **WHEN** activation fails during adoption
- **THEN** the earlier layout is restored and still accepts the certificates it accepted before

#### Scenario: Host trusting an unrelated CA
- **GIVEN** a host whose sshd trusts a user CA that is not in the bundle
- **WHEN** the role runs preflight
- **THEN** the host is reported `ineligible` with reason `unmanaged_ca_conflict` and is not changed

### Requirement: Account handling follows the bundle's account mode
The role SHALL require an account in mode `existing` to be present already, and SHALL create an account in mode `managed` when it is absent.
A managed account is created with a locked password, a login shell, a home directory and no supplementary groups, and the role records that it created the account. The role never grants sudo, never changes an account it did not create, never accepts `root` or UID 0, and reports `account_missing` for an absent `existing` account and `account_not_managed` when a `managed` account name already belongs to an account the role did not create. Offboarding removes the account's principals and leaves the account and its files in place.

#### Scenario: Managed account on a new host
- **GIVEN** a bundle listing account `svc-ops` in mode `managed`
- **WHEN** the role enrolls a host where `svc-ops` does not exist
- **THEN** the account exists with a locked password and no supplementary groups

#### Scenario: Existing account is missing
- **GIVEN** a bundle listing account `svc-ops` in mode `existing`
- **WHEN** the role runs preflight on a host without it
- **THEN** the host is reported `ineligible` with reason `account_missing`

#### Scenario: Managed name collides with an operator's account
- **GIVEN** a host where `svc-ops` exists and was not created by the role
- **WHEN** the bundle lists `svc-ops` in mode `managed`
- **THEN** the host is reported `ineligible` with reason `account_not_managed`

### Requirement: Elevated targets are enrolled only by explicit class
The role SHALL accept the risk class `elevated` in addition to `standard`, SHALL take the class only from the bundle, and SHALL refuse a host whose observed nature is a hypervisor when the bundle's class is `standard`.
For an elevated host the role runs one host at a time, keeps the transactional rollback of the standard class, and leaves root login, root keys and cluster-internal SSH configuration untouched. The supported elevated platform is Proxmox VE on a supported Debian release.

#### Scenario: Hypervisor delivered as standard
- **GIVEN** a host on which the role detects a hypervisor installation
- **WHEN** the bundle's risk class is `standard`
- **THEN** the host is reported `ineligible` with reason `elevated_target` and is not changed

#### Scenario: Hypervisor delivered as elevated
- **WHEN** the bundle's risk class is `elevated` for a supported hypervisor
- **THEN** the host is enrolled with the single layout and root access is unchanged

### Requirement: Supported platforms pass in their stock configuration
The role SHALL enroll every platform release it declares supported in that release's stock sshd configuration, including the release's default sshd activation mode, and its test matrix SHALL prove this for virtual machines and for system containers.
A platform the role does not support is reported `ineligible` with reason `platform_unsupported` before any change. Hosts without systemd and operating-system families outside the declared list are not supported by the role.

#### Scenario: Stock install of a supported release
- **WHEN** the role runs preflight on an unmodified install of a supported release
- **THEN** the host is eligible

#### Scenario: Container guest
- **WHEN** the role enrolls a supported release running as a system container
- **THEN** the result is the same as for a virtual machine of that release

### Requirement: Enrollment results are structured and include host public keys
The role SHALL emit, for every host and phase, one structured result containing the device UID from the bundle, the bundle generation and digest, the outcome, any ineligibility reason, the adopted layout if any, and the host's public SSH host keys.
The result contains no private key and no principal. The role reads host keys and never creates, replaces or removes them. In integrated mode the result is emitted as a host-scoped job event; in direct mode it is also submitted to the ServiceRadar admin API.

#### Scenario: Committed enrollment
- **WHEN** the role commits an enrollment
- **THEN** the result carries outcome `committed`, the generation and digest applied, and the host's public host keys

#### Scenario: Result content
- **WHEN** any result is inspected
- **THEN** it contains no principal and no private key material

### Requirement: Direct mode reads its hosts and values from ServiceRadar
The content SHALL provide an inventory plugin that builds the direct-mode inventory from the ServiceRadar enrollment bundle API, one host per device UID, with every role input taken from the bundle.
The plugin authenticates with an API token supplied through the controller's environment, verifies TLS, and exposes the device's management address as the connection address, which the operator may override without affecting identity. A role input for accounts, principals, CA keys, risk class or target identity that comes from any source other than the plugin fails the run before any host is changed.

#### Scenario: Direct run with no hand-written host variables
- **WHEN** an operator runs the direct playbooks with the inventory plugin and an access rule filter
- **THEN** each covered device appears as a host named by its device UID with its bundle values
- **AND** no inventory file was written by hand

#### Scenario: Operator overrides a principal in group variables
- **WHEN** a group variable sets an account's principals
- **THEN** the run fails before changing any host
