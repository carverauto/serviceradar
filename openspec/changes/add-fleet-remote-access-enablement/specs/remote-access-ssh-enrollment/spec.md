## ADDED Requirements

### Requirement: Desired enrollment state is derived from access rules
The system SHALL maintain the complete set of device accounts by evaluating every enabled access rule's target query over the whole inventory, without sampling, whenever a rule changes and on a bounded schedule.
A device account that no enabled access rule supports any longer becomes undesired. Its principals are revoked at once, so no certificate can be issued with them; its readiness state becomes `drifted` with reason `removal_pending`; and it is omitted from the device's enrollment bundle, so that the next enrollment removes its principals file from the host. The device account is deleted when a `committed` or `unchanged` enrollment result is recorded for a generation whose bundle omitted it. If a rule supports the same Unix account on the device again before that, the device account becomes desired again with a newly generated current principal and readiness state `not_enrolled` with reason `principal_revoked`. Each device has an enrollment generation, an integer that increases whenever the device's desired accounts, principals or CA keys change.

#### Scenario: Device newly matches a rule
- **GIVEN** an enabled access rule listing account `svc-ops`
- **WHEN** a device is discovered that matches the rule's target query
- **THEN** within the reconciliation interval a device account exists for it with readiness state `not_enrolled`

#### Scenario: Rule covering more devices than a preview shows
- **WHEN** an access rule's target query matches more devices than the rule preview displays
- **THEN** every matching device receives a device account

#### Scenario: Rule disabled
- **WHEN** the only access rule supporting a device account is disabled
- **THEN** the device account's principals are revoked and no certificate is issued for it
- **AND** its readiness state is `drifted` with reason `removal_pending`
- **AND** it is omitted from the device's bundle and the device's enrollment generation increases

#### Scenario: Removal confirmed by enrollment
- **GIVEN** a device account pending removal
- **WHEN** a `committed` result is recorded for a generation whose bundle omitted it
- **THEN** the device account is deleted

#### Scenario: Rule re-enabled before the host was changed
- **GIVEN** a device account pending removal whose host has not been enrolled since
- **WHEN** the access rule is enabled again
- **THEN** the device account is desired again with a newly generated current principal
- **AND** its readiness state is `not_enrolled` with reason `principal_revoked` until the device is enrolled again and probed

### Requirement: The enrollment bundle is the only source of per-host enrollment values
The system SHALL produce, for each device with at least one enrollable desired device account or at least one device account pending removal, one enrollment bundle derived from stored state, and every enrollment channel SHALL take its per-host values from that bundle and from nowhere else.
A device account is enrollable unless the device is excluded or is elevated without opt-in (see "Supported targets and explicit exclusions"). A bundle contains the device UID, the enrollment generation, a digest of its content, the public keys and fingerprints of the CA records in an active or overlap state, each enrollable desired account with its mode and its non-revoked principals (a device account pending removal is never listed), the device's risk class, and whether a host-key change is authorized. It contains no private key, token or password. Reading bundles requires `devices.remote_access.ssh.ca_bundle.read`. A hand-written inventory variable, survey answer or extra variable cannot supply or override a bundle value.

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
The system SHALL store, for every device account, exactly one readiness state from `not_enrolled`, `pending`, `verified`, `drifted` and `unreachable`, with exactly one reason from the closed list for that state and a remedy, and no writer SHALL set a state and reason pair outside these lists.
The reasons are, by state. `not_enrolled`: `never_enrolled`, `certificate_rejected`, `principal_revoked`, `platform_unsupported`, `elevated_not_opted_in`, `excluded`. `pending`: `awaiting_probe`, `host_key_unknown`, `probe_unsupported`. `verified`: `ok`. `drifted`: `certificate_rejected`, `host_key_changed`, `target_held`, `removal_pending`. `unreachable`: `no_routing_agent`, `agent_offline`, `tcp_unreachable`, `probe_timeout`.
A device account is probe-eligible when it is desired, its device is not excluded, and it is not elevated without opt-in. The writers, and the only pairs each sets, are:
- Reconciliation: `not_enrolled`/`never_enrolled` for a new device account; `not_enrolled`/`excluded` while its device is excluded; `not_enrolled`/`elevated_not_opted_in` while it is elevated without opt-in; `pending`/`awaiting_probe`, with a probe scheduled, when such an exclusion or opt-in hold ends; `drifted`/`removal_pending` when it becomes undesired; `not_enrolled`/`principal_revoked` when it becomes desired again; `pending`/`probe_unsupported` under the legacy probe allowance below.
- Principal revocation: `not_enrolled`/`principal_revoked`.
- Enrollment results, as "Enrollment results are recorded" defines: `pending`/`awaiting_probe`, `not_enrolled`/`platform_unsupported`, `drifted`/`target_held`.
- Readiness probes, as "Readiness probe" defines: `verified`/`ok`; on rejection, `drifted`/`certificate_rejected` for a device account that has been `verified` before and `not_enrolled`/`certificate_rejected` for one that has not; `pending`/`host_key_unknown`; `drifted`/`host_key_changed`; `unreachable` with one of its four reasons.
- Host-key refusal of a session: `pending`/`host_key_unknown` and `drifted`/`host_key_changed`.
Enrollment results, probes and host-key refusals change only probe-eligible device accounts; a device account with reason `excluded`, `elevated_not_opted_in` or `removal_pending` keeps its state and reason. Only a successful readiness probe sets `verified`; nothing else does.
A certificate is issued for a device account only while its state is `verified`, plus one bounded issuance allowance, the legacy probe allowance: a certificate may also be issued for a device account that holds a previous principal with origin `import` and has never been probed because the agent that routes to its device does not advertise probe support. Such a device account has state `pending` with reason `probe_unsupported`, and the surface states that readiness cannot be checked until the agent is upgraded. The allowance ends for the device account when that agent advertises probe support, whereupon a probe is scheduled and only the `verified` gate applies, and it ends for every device account in release N+1 of the retirement timeline of `remoteAccess.sshCertificatePolicy` (see "Retired deployment values"). A session issued under the allowance never changes the readiness state.

#### Scenario: Enrollment committed but not yet probed
- **GIVEN** device accounts that are not `verified`
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

#### Scenario: First probe is rejected
- **GIVEN** a device account that has never been `verified`
- **WHEN** a readiness probe's certificate is rejected by the host
- **THEN** the state is `not_enrolled` with reason `certificate_rejected`

#### Scenario: Host key changes on a device with an excluded account
- **GIVEN** a device with one probe-eligible device account and one device account with reason `elevated_not_opted_in`
- **WHEN** an agent is offered a host key that is not among the device's trusted keys
- **THEN** the probe-eligible device account is `drifted` with reason `host_key_changed`
- **AND** the other device account keeps reason `elevated_not_opted_in`

#### Scenario: Certificate request for an unverified device account
- **GIVEN** a device account outside the legacy probe allowance
- **WHEN** an actor requests a certificate for a device account that is not `verified`
- **THEN** the request is denied with `not_ready` carrying the state, reason and remedy

#### Scenario: Imported grant behind an agent that predates the probe
- **GIVEN** a device account with a previous principal of origin `import` that has never been probed
- **AND** an agent routing to its device that does not advertise probe support
- **WHEN** a permitted actor requests a certificate
- **THEN** the certificate is issued under the legacy probe allowance
- **AND** the device account stays `pending` with reason `probe_unsupported`

#### Scenario: Agent upgraded during the allowance
- **GIVEN** a device account under the legacy probe allowance
- **WHEN** the agent routing to its device advertises probe support
- **THEN** a readiness probe is scheduled
- **AND** certificates are issued for the device account only once it is `verified`

#### Scenario: New grant behind an agent that predates the probe
- **GIVEN** a device account with no previous principal of origin `import`
- **AND** an agent routing to its device that does not advertise probe support
- **WHEN** a permitted actor requests a certificate
- **THEN** the request is denied with `not_ready` and a remedy to upgrade the agent

### Requirement: Readiness probe
The system SHALL verify a probe-eligible device account by having the routing agent authenticate to the host with a system-issued probe certificate for that device account and disconnect after authentication without requesting a session channel.
A probe certificate carries exactly one principal of the device account, a lifetime of at most 60 seconds, a forced no-op command, no permit extensions, and a key ID that marks it as a probe. The agent never requests a channel on a probe connection, so the forced command never runs; it exists only to make the certificate useless if it leaves the agent. A probe first presents a certificate carrying the current principal alone. When the host rejects it and the device account holds a previous principal, the probe presents a second certificate carrying the previous principal alone. Success with the current principal sets `verified`/`ok` and revokes the previous principal; success with only the previous principal sets `verified`/`ok` and keeps it; rejection of every certificate sets the rejection pair of "Per-device-account readiness state", without claiming whether the CA trust or the principal is missing. The probe verifies the host key against the central host-key store exactly as a session does. The agent never reads a file on the host. A probe runs after an enrollment result, on request by any principal who may open an SSH session to the device, once for a device account holding a previous principal with origin `import`, when the legacy probe allowance ends for a device account, and periodically for device accounts that are `verified`, `drifted` or `unreachable`, at an interval that is a runtime setting (default 24 hours, may be disabled). Probes are rate-limited per agent.

#### Scenario: Probe opens no channel
- **WHEN** a probe connection completes certificate authentication
- **THEN** the agent disconnects without requesting a session channel
- **AND** the forced no-op command is not executed on the host

#### Scenario: Agent offline at probe time
- **WHEN** a probe is due and no agent that can route to the device is connected
- **THEN** the state is `unreachable` with reason `agent_offline`
- **AND** a previously recorded `verified` time is kept as evidence

#### Scenario: Periodic probe disabled
- **GIVEN** the periodic probe interval is disabled
- **THEN** probes still run after enrollment results and on request

### Requirement: Enrollment results are recorded
The system SHALL record, for every enrollment attempt on a device, the channel, the launching principal, the bundle generation and digest applied, the outcome, any pre-existing layout that was adopted, and the host's public host keys.
The outcomes are `committed`, `unchanged`, `rolled_back`, `failed_before_mutation`, `ineligible` (with the content's reason) and `critical_manual_recovery`. The integrated channel takes results from the job's host-scoped events; the direct channel submits them to the admin API with a token holding `devices.remote_access.ssh.enrollment.report`. A result is accepted only for the device UID the bundle was issued to, and changes readiness only for the probe-eligible device accounts that the applied generation's bundle listed. A `committed` or `unchanged` result for the device's current generation sets each listed device account that is not `verified` to `pending` with reason `awaiting_probe`, and schedules a probe for every listed device account; a `verified` device account stays `verified` until that probe. A `committed` or `unchanged` result for any generation deletes each device account pending removal that the applied bundle omitted. An `ineligible` result with the content's reason `platform_unsupported` sets the listed device accounts to `not_enrolled` with reason `platform_unsupported`. Every other `ineligible` result, and every `rolled_back` or `failed_before_mutation` result, leaves state and reason unchanged, and the content's reason is shown with the state as remedy detail. `critical_manual_recovery` sets the listed device accounts to `drifted` with reason `target_held` and, on the integrated channel, is subject to the launch boundary's durable target hold.

#### Scenario: Result for a superseded generation
- **WHEN** a result reports a commit for a generation older than the device's current one
- **THEN** the result is recorded
- **AND** no device account is set to `awaiting_probe` by it

#### Scenario: Reporter without the permission
- **WHEN** a token without `devices.remote_access.ssh.enrollment.report` submits a result
- **THEN** the submission is denied and audited

### Requirement: Readiness is visible before Connect
The system SHALL show, on a device's remote-access surface and before any connection is attempted, each device account available to the viewing actor with its readiness state, reason and remedy, and SHALL offer Connect only for device accounts that the issuance gate of "Per-device-account readiness state" admits.
The decision shown is produced by the same evaluation that authorizes a certificate request. For a device account the gate does not admit, the surface offers the remedy: a readiness check for a probe-eligible device account, the enrollment channels, or the administrator action the reason names. Settings provides a deployment-wide enrollment view that counts device accounts by state and reason, filters by access rule, and exports the list through the admin API. These views load data only after the LiveView is connected and stream lists longer than 100 rows.

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
