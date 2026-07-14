## Context

VirtIO-Win media commonly exposes `guest-agent/qemu-ga-x86_64.msi` to a Windows
guest. Some upstream QGA MSI builds are not Authenticode-signed even when the
parent ISO is obtained from the official archive. A generic public role must
distinguish that narrow, operator-reviewed mounted-media exception from an
unsafe unsigned network download.

AWX 24.6.1 ships Ansible Core 2.15.12 and `ansible.windows 2.4.0`. The 3.x
collection line requires a newer Ansible Core. Pairing those unsupported
versions just to use `win_package.verify_signature` is not an acceptable
production contract.

## Decisions

### Artifact trust is checksum-first and source-specific

Both acquisition modes require an exact SHA-256. HTTPS rejects userinfo,
queries, fragments, disabled TLS validation, and moving `latest` URLs. Mounted
media requires an absolute MSI path on a Windows logical disk whose drive type
is CD-ROM. The role inspects Authenticode with PowerShell immediately before
package execution; `win_package` independently rechecks the same SHA-256.

The default requires `Valid`. `allow_unsigned_pinned_iso` is legal only for the
mounted-CD-ROM source and accepts only `Valid` or `NotSigned`. It never permits
`HashMismatch`, `NotTrusted`, `UnknownError`, or an unsigned HTTPS download.

### Management access and VM hardware are prerequisites

QGA cannot bootstrap WinRM or OpenSSH because Ansible needs a management
transport before it can run. The role also does not change PVE VM hardware or
install the VirtIO serial driver blindly. It requires a healthy matching PnP
device before claiming readiness.

### Reboots require a launch-time operator choice

The default `never` policy records and reports an MSI-required reboot, then
fails without restarting Windows. `if_required` follows return code 3010;
`on_change` reboots after an install/upgrade. An already converged host is not
rebooted.

### End-to-end proof terminates at Proxmox

A running Windows service is necessary but not sufficient. After the role
converges, the operator must prove the other endpoint with the authenticated
PVE API or `qm agent <vmid> ping` against the exact VM identity.

### ServiceRadar is the production launch surface

One direct-AWX canary is acceptable to validate WinRM, the machine credential,
the execution environment, and role behavior before ServiceRadar integration
exists. Subsequent idempotence and fleet executions must use ServiceRadar so
the real human RBAC, immutable membership/template binding, result persistence,
and audit path are exercised.

## Risks and Mitigations

- **Unsigned upstream MSI:** limited to a pinned digest on verified CD-ROM
  media; every other signature status/source combination fails.
- **Wrong guest or duplicate hostname:** ServiceRadar launch uses immutable AWX
  membership and canonical device identity; names and IPs are display evidence.
- **Credential leakage:** the public repository contains no credential, and
  the Windows machine credential remains an encrypted AWX resource.
- **Unexpected downtime:** reboot defaults to disabled and requires an explicit
  pre-launch policy.
- **Controller/runtime drift:** AWX project commit, content digest, execution
  environment digest, collection version, inventory, template, and credential
  IDs are reviewed and rebound on drift.
