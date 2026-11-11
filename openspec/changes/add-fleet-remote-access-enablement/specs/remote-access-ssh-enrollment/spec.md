## ADDED Requirements

### Requirement: Desired enrollment state is derived from access rules
The system SHALL maintain the complete set of device accounts by evaluating every enabled access rule's target query over the whole inventory, without sampling, whenever a rule changes and on a bounded schedule.
A device account that no enabled access rule supports any longer becomes undesired: no certificate can be issued for it, because no rule qualifies, and it is omitted from the device's enrollment bundle so that the next enrollment removes it from the host. Its principals are kept until an enrollment result shows the host no longer lists them, and are then revoked; if a rule supports the device account again before that, it becomes desired again with the same principals and is probed. Each device has an enrollment generation, an integer that increases whenever the device's desired accounts, principals or CA keys change.

#### Scenario: Device newly matches a rule
- **GIVEN** an enabled access rule listing account `svc-ops`
- **WHEN** a device is discovered that matches the rule's target query
- **THEN** within the reconciliation interval a device account exists for it with readiness state `not_enrolled`

#### Scenario: Rule covering more devices than a preview shows
- **WHEN** an access rule's target query matches more devices than the rule preview displays
- **THEN** every matching device receives a device account

#### Scenario: Rule disabled
- **WHEN** the only access rule supporting a device account is disabled
- **THEN** the device account is undesired and is omitted from the device's bundle
- **AND** the device's enrollment generation increases

#### Scenario: Rule re-enabled before the host was changed
- **GIVEN** an undesired device account whose host has not been enrolled since
- **WHEN** the access rule is enabled again
- **THEN** the device account is desired again with the same principals
- **AND** a readiness probe is scheduled

### Requirement: The enrollment bundle is the only source of per-host enrollment values
The system SHALL produce, for each device with at least one enrollable desired device account, one enrollment bundle derived from stored state, and every enrollment channel SHALL take its per-host values from that bundle and from nowhere else.
A device account is enrollable unless the device is excluded or is elevated without opt-in (see "Supported targets and explicit exclusions"). A bundle contains the device UID, the enrollment generation, a digest of its content, the public keys and fingerprints of the CA records in an active or overlap state, each enrollable desired account with its mode and its non-revoked principals, the device's risk class, and whether a host-key change is authorized. It contains no private key, token or password. Reading bundles requires `devices.remote_access.ssh.ca_bundle.read`. A hand-written inventory variable, survey answer or extra variable cannot supply or override a bundle value.

#### Scenario: Same values through every channel
- **GIVEN** a device with a desired device account
- **WHEN** its bundle is read through the admin API, delivered through an AWX callback response, and shown in the manual instructions
- **THEN** all three carry the same generation, digest, CA keys, accounts and principals

#### Scenario: Reader without the permission
- **WHEN** a principal without `devices.remote_access.ssh.ca_bundle.read` requests a bundle
- **THEN** the request is denied and audited

#### Scenario: Inventory variable tries to set a principal
- **WHEN** an enrollment run finds an account, principal or CA key supplied by an inventory, group or host variable
- **THEN** the run fails before changing any host

### Requirement: One on-host layout
The system SHALL define exactly one on-host layout for certificate trust, and every enrollment channel and every product document SHALL produce that layout.
The layout is: a drop-in `/etc/ssh/sshd_config.d/10-serviceradar-remote-access.conf` setting `TrustedUserCAKeys /etc/ssh/serviceradar/current/trusted-user-ca-keys.pub` and `AuthorizedPrincipalsFile /etc/ssh/serviceradar/current/authorized-principals/%u`; the CA bundle at the first path; and one file per account in the second directory containing that device account's principals, one per line.

#### Scenario: Documentation matches the automated layout
- **WHEN** an operator follows the manual instructions for a device
- **THEN** the files and directives on the host are the same as an automated enrollment would write

### Requirement: Enrollment channels
The system SHALL support three enrollment channels that converge on the same bundle, layout and readiness verification: `integrated` (an AWX job that receives bundles through the callback response), `direct` (an Ansible run on an operator's controller that reads bundles through the admin API), and `manual` (an operator applies the values ServiceRadar shows for one device).
ServiceRadar never starts an enrollment that an authorized principal did not launch. The manual channel's instructions are a rendering of the bundle and require the same permission as reading it. An integrated enrollment is launched with `ansible.runs.launch` and `devices.remote_access.ssh.ca_bundle.read`, targets hosts only by the immutable AWX membership tuple linked to the canonical device, and is partitioned so that no child job exceeds the per-child target limit of the launch boundary. A device that is not launchable through AWX is reported with the AWX target-readiness reason and remains enrollable through the other channels. A direct enrollment authenticates to the admin API with an API token holding `devices.remote_access.ssh.ca_bundle.read`. The response policy bound to an integrated callback grant is derived from the stored bundles at grant time; it is not read from a server-owned file.

#### Scenario: Deployment without AWX
- **GIVEN** a deployment with no AWX controller
- **WHEN** an operator runs the direct channel against the devices an access rule covers
- **THEN** each host is enrolled from its bundle and no per-host variable was written by hand

#### Scenario: Rule covering more hosts than one child job may target
- **WHEN** an integrated enrollment is launched for more devices than the per-child target limit
- **THEN** the devices are divided among several child jobs, each within the limit
- **AND** each child receives only its own targets' bundles

#### Scenario: Device not in any AWX inventory
- **WHEN** an integrated enrollment is requested for a device with no approved AWX membership
- **THEN** the device is reported with its AWX target-readiness reason and is not launched
- **AND** the direct and manual channels remain available for it

### Requirement: Supported targets and explicit exclusions
The system SHALL classify each device for enrollment as `standard`, `elevated` or excluded, and SHALL enroll an elevated device only under explicit opt-in.
A device is `elevated` when ServiceRadar's stored virtualization relationship identifies it as a hypervisor host. An elevated device account is enrollable only when at least one enabled access rule that covers the device and lists the account has `allow_elevated_targets` set. An administrator with `settings.credentials.manage` can exclude any device from enrollment; exclusion is stored outside the device record, is audited, and is how nodes that host the deployment's own control plane are kept out until ServiceRadar can identify them. Automated channels support the platforms the public enrollment content declares; any other platform is reported as `platform_unsupported` and is enrollable through the manual channel only.

#### Scenario: Hypervisor covered by a rule without opt-in
- **GIVEN** a hypervisor host covered by an access rule that does not set `allow_elevated_targets`
- **THEN** its device account has readiness state `not_enrolled` with reason `elevated_not_opted_in`
- **AND** no channel delivers a bundle for it

#### Scenario: Excluded device
- **WHEN** an administrator excludes a device from enrollment
- **THEN** its device accounts have readiness state `not_enrolled` with reason `excluded`
- **AND** no channel delivers a bundle for it

#### Scenario: Guest on an unsupported platform
- **GIVEN** a guest whose platform the enrollment content does not support
- **WHEN** an automated enrollment preflight runs against it
- **THEN** its device accounts have readiness state `not_enrolled` with reason `platform_unsupported` and a remedy pointing to the manual channel

### Requirement: Per-device-account readiness state
The system SHALL store, for every desired device account, exactly one readiness state from `not_enrolled`, `pending`, `verified`, `drifted` and `unreachable`, with exactly one reason and a remedy.
The reasons are, by state. `not_enrolled`: `never_enrolled`, `principal_revoked`, `platform_unsupported`, `elevated_not_opted_in`, `excluded`. `pending`: `enrollment_running`, `awaiting_probe`, `host_key_unknown`. `verified`: `ok`. `drifted`: `certificate_rejected`, `host_key_changed`, `target_held`. `unreachable`: `no_routing_agent`, `agent_offline`, `tcp_unreachable`, `probe_timeout`. Only a successful readiness probe sets `verified`; an enrollment result never does. A rejected certificate sets `drifted` only for a device account that was verified before; otherwise the state stays `not_enrolled`. A certificate is issued for a device account only while its state is `verified`. The one exception is a device account whose routing agent does not advertise probe support: the issuance gate does not apply to it, a successful certificate session sets `verified`, a rejected one is classified as a probe rejection would be, and the surface states that readiness cannot be checked in advance until the agent is upgraded.

#### Scenario: Enrollment committed but not yet probed
- **WHEN** an enrollment result reports a commit for a device's current generation
- **THEN** its device accounts are `pending` with reason `awaiting_probe`
- **AND** a readiness probe is scheduled without operator action

#### Scenario: Principals file removed from an enrolled host
- **GIVEN** a verified device account
- **WHEN** a readiness probe's certificate is rejected by the host
- **THEN** the state is `drifted` with reason `certificate_rejected` and a remedy to enroll the device again

#### Scenario: Host enrolled by hand
- **GIVEN** a device account in state `not_enrolled`
- **WHEN** an operator applies the manual instructions and requests a readiness check that succeeds
- **THEN** the state is `verified`

#### Scenario: Certificate request for an unverified device account
- **GIVEN** a routing agent that advertises probe support
- **WHEN** an actor requests a certificate for a device account that is not `verified`
- **THEN** the request is denied with `not_ready` carrying the state, reason and remedy

#### Scenario: Routing agent predates the probe
- **GIVEN** a device account whose routing agent does not advertise probe support
- **WHEN** a permitted actor requests a certificate and the session authenticates
- **THEN** the certificate is issued without a prior probe
- **AND** the device account becomes `verified`

### Requirement: Readiness probe
The system SHALL verify a device account by having the routing agent authenticate to the host with a system-issued probe certificate for that device account and disconnect without opening a session channel.
A probe certificate carries the device account's principals under test, a lifetime of at most 60 seconds, a forced no-op command, no permit extensions, and a key ID that marks it as a probe; the agent refuses to open a channel on a probe connection. The probe verifies the host key against the central host-key store exactly as a session does. Its result is classified into the readiness states and reasons; success proves that the host trusts the CA and lists the principal for that account, and a rejection is reported as `certificate_rejected` without claiming which of the two is missing. The agent never reads a file on the host. A probe runs after an enrollment result, on request by any principal who may open an SSH session to the device, once for a device account holding an imported legacy principal, and periodically for device accounts that are `verified`, `drifted` or `unreachable`, at an interval that is a runtime setting (default 24 hours, may be disabled). Probes are rate-limited per agent.

#### Scenario: Probe cannot run commands
- **WHEN** a probe certificate is used to request a shell or a command
- **THEN** the host runs only the forced no-op command
- **AND** the agent does not request a channel

#### Scenario: Agent offline at probe time
- **WHEN** a probe is due and no agent that can route to the device is connected
- **THEN** the state is `unreachable` with reason `agent_offline`
- **AND** a previously recorded `verified` time is kept as evidence

#### Scenario: Periodic probe disabled
- **GIVEN** the periodic probe interval is disabled
- **THEN** probes still run after enrollment results and on request

### Requirement: Enrollment results are recorded
The system SHALL record, for every enrollment attempt on a device, the channel, the launching principal, the bundle generation and digest applied, the outcome, any pre-existing layout that was adopted, and the host's public host keys.
The outcomes are `committed`, `unchanged`, `rolled_back`, `failed_before_mutation`, `ineligible` (with the content's reason) and `critical_manual_recovery`. The integrated channel takes results from the job's host-scoped events; the direct channel submits them to the admin API with a token holding `devices.remote_access.ssh.enrollment.report`. A result is accepted only for the device UID the bundle was issued to. An `ineligible` result leaves the readiness state unchanged, except that the content's reason `platform_unsupported` sets the readiness reason of the same name; the content's reason is shown with the state as remedy detail. `critical_manual_recovery` sets the device's accounts to `drifted` with reason `target_held` and, on the integrated channel, is subject to the launch boundary's durable target hold.

#### Scenario: Result for a superseded generation
- **WHEN** a result reports a commit for a generation older than the device's current one
- **THEN** the result is recorded
- **AND** the device accounts changed since that generation are not marked `awaiting_probe`

#### Scenario: Reporter without the permission
- **WHEN** a token without `devices.remote_access.ssh.enrollment.report` submits a result
- **THEN** the submission is denied and audited

### Requirement: Readiness is visible before Connect
The system SHALL show, on a device's remote-access surface and before any connection is attempted, each device account available to the viewing actor with its readiness state, reason and remedy, and SHALL offer Connect only for device accounts that the issuance gate of "Per-device-account readiness state" admits.
The decision shown is produced by the same evaluation that authorizes a certificate request. For a device account the gate does not admit, the surface offers the remedy: a readiness check, the enrollment channels, or the administrator action the reason names. Settings provides a deployment-wide enrollment view that counts device accounts by state and reason, filters by access rule, and exports the list through the admin API. These views load data only after the LiveView is connected and stream lists longer than 100 rows.

#### Scenario: Unenrolled device
- **GIVEN** a device account in state `not_enrolled` with reason `never_enrolled`
- **WHEN** a permitted actor opens the device's remote-access surface
- **THEN** the surface states that the host is not enrolled and how to enroll it
- **AND** Connect is not offered for certificate mode

#### Scenario: Actor with no covering rule
- **WHEN** an actor whom no access rule admits opens the surface
- **THEN** the surface states the classified reason and that an administrator must grant access in Settings

#### Scenario: Fleet view
- **WHEN** an administrator opens the enrollment view for an access rule
- **THEN** the view shows how many covered device accounts are in each state and lists them with reasons
