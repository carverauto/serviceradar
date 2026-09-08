## ADDED Requirements

### Requirement: Public automation installs QEMU Guest Agent without carrying credentials
ServiceRadar SHALL publish reusable Ansible content that installs and verifies
QEMU Guest Agent on an already manageable 64-bit Windows guest. The repository
MUST NOT contain Windows, AWX, Proxmox, or ServiceRadar credentials and MUST NOT
bootstrap WinRM/OpenSSH, create accounts, or mutate PVE VM hardware.

#### Scenario: Operator imports the public content
- **WHEN** an operator imports a reviewed immutable revision into AWX
- **THEN** root install and read-only preflight playbooks are discoverable with
  typed variables and no environment-specific credential or private lab data

#### Scenario: Management access is absent
- **WHEN** the guest has no working WinRM/OpenSSH management transport
- **THEN** documentation identifies management bootstrap as a prerequisite and
  the role makes no claim that QGA can establish that initial access

### Requirement: Every MSI is pinned and source policy is fail-closed
The role SHALL require an exact SHA-256 for every MSI. HTTPS sources MUST use a
literal credential-free `.msi` URL with certificate validation and no query or
fragment. Mounted sources MUST be absolute paths on guest-reported CD-ROM media.
Authenticode MUST be `Valid` by default. Only an explicit mounted-media policy
MAY accept `NotSigned`, and every other invalid signature state MUST fail before
package execution. Package execution SHALL independently recheck SHA-256.

#### Scenario: Signed HTTPS package is selected
- **WHEN** an HTTPS MSI has the pinned digest and `Valid` Authenticode status
- **THEN** the role may install it and removes its transient downloaded copy on
  both success and failure

#### Scenario: Unsigned mounted upstream package is explicitly accepted
- **WHEN** the MSI is on verified CD-ROM media, its digest exactly matches the
  operator-reviewed value, and policy is `allow_unsigned_pinned_iso`
- **THEN** `NotSigned` may proceed while `HashMismatch`, `NotTrusted`,
  `UnknownError`, and all other invalid states remain denied

#### Scenario: Unsigned network package is supplied
- **WHEN** an HTTPS MSI is unsigned or a URL contains credentials, query,
  fragment, disabled TLS verification, or moving `latest` content
- **THEN** the role fails before executing the package

### Requirement: Readiness includes VirtIO, service, binary, and PVE proof
The role SHALL require a healthy VirtIO serial PnP device unless the operator
explicitly selected non-ready staging. It SHALL converge `QEMU-GA` to automatic
and running, resolve its actual binary, and require a non-empty file version.
End-to-end readiness additionally requires an authenticated PVE-side guest-agent
ping for the exact VM.

#### Scenario: Guest converges without reboot
- **WHEN** the package installs with return code 0 and no reboot requirement
- **THEN** the service is automatic/running, the binary/version checks pass, and
  an independent PVE guest-agent ping can prove the host-to-guest channel

#### Scenario: VirtIO serial is absent or unhealthy
- **WHEN** no matching healthy PnP device exists
- **THEN** a readiness launch fails before package mutation unless the operator
  explicitly chose staging that makes no readiness claim

### Requirement: Reboots are explicit and idempotence is proven through ServiceRadar
The default reboot policy SHALL be `never`. An MSI-required reboot MUST be
reported without restarting Windows. Ansible MAY reboot only when the operator
selected `if_required` or `on_change` before launch. After the initial plumbing
canary, later idempotence and fleet executions SHALL originate from
ServiceRadar's authenticated Ansible launch path using the current human actor,
immutable AWX membership, reviewed template binding, exact limit, and persisted
result/audit flow.

#### Scenario: MSI requests reboot under the default policy
- **WHEN** installation returns a reboot-required result and policy is `never`
- **THEN** the role reports the partial state and stops without rebooting

#### Scenario: ServiceRadar reruns a converged canary
- **WHEN** an authorized user launches the reviewed immutable binding from
  ServiceRadar against the exact already-converged guest
- **THEN** AWX receives only the exact target and reviewed non-secret inputs,
  the role reports no changes, and ServiceRadar persists the result/audit trail

#### Scenario: Direct AWX fleet launch is attempted after the canary
- **WHEN** an operator tries to use direct AWX as the normal fleet workflow
- **THEN** the documented rollout remains blocked until the ServiceRadar-owned
  launch path and collision-safe inventory identities are proven
