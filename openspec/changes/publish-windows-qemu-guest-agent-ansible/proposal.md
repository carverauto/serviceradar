# Change: Publish Windows QEMU Guest Agent Ansible content

## Why

ServiceRadar discovers Windows guests through Proxmox, but a guest without the
QEMU Guest Agent cannot provide the authenticated host-to-guest control channel
needed for reliable inventory, readiness checks, and later console workflows.
Operators need reusable public automation instead of a lab-specific script.

The automation must not bootstrap management access, carry Windows or Proxmox
credentials, download a moving `latest` artifact, silently accept unsigned
network content, or reboot a guest without an explicit maintenance policy.

## What Changes

- Publish a reusable Windows QEMU Guest Agent role plus root AWX-discoverable
  install and read-only preflight wrappers in `serviceradar-ansible`.
- Support an exact HTTPS MSI or an exact MSI on mounted CD-ROM media; require a
  pinned SHA-256 in both modes and require `Valid` Authenticode by default.
- Permit upstream `NotSigned` media only through the explicit
  `allow_unsigned_pinned_iso` policy, only on verified CD-ROM media, and only
  with the pinned MSI digest. Refuse every other invalid signature state.
- Require a healthy VirtIO serial device, install/upgrade idempotently, keep
  `QEMU-GA` automatic/running, and verify the service binary and version.
- Default to no reboot. Surface MSI-required reboot state and allow Ansible to
  reboot only when the operator selected `if_required` or `on_change` before
  launch.
- Pin a supported AWX 24.6.1 execution environment and `ansible.windows 2.4.0`
  contract, with explicit PowerShell Authenticode inspection followed by the
  independent `win_package` SHA-256 check.
- Publish documentation, non-secret inventory examples, repository contracts,
  lint/syntax gates, and immutable collection/content provenance.
- Prove the role on one controlled Windows/Proxmox canary, then require later
  idempotence and fleet launches to originate from ServiceRadar's reviewed
  Ansible launch path rather than directly from AWX.

## Impact

- Affected specs: `windows-qemu-guest-agent-automation` (new)
- Affected repository: `https://code.carverauto.dev/carverauto/serviceradar-ansible`
- ServiceRadar prerequisites: immutable AWX membership and template binding,
  current human `ansible.runs.launch` permission, exact inventory limit, and a
  reviewed machine credential held only by AWX
- Proxmox prerequisite: the exact VM has the QEMU guest-agent channel enabled
  and the matching VirtIO serial device available to Windows
- Explicitly out of scope: WinRM/OpenSSH bootstrap, Windows account creation,
  credential storage in ServiceRadar or git, Proxmox hardware mutation, guest
  reboot without prior policy, graphical console transport, and SSH/RDP access
