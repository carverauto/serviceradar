# Change: Add native Proxmox guest terminal consoles

## Why

ServiceRadar can currently open a browser terminal to an authorized Proxmox
PVE host, but device-detail actions for QEMU and LXC guests stay unavailable.
Treating a guest as a generic SSH target would either require unrelated guest
credentials or bypass Proxmox's intended short-lived console-ticket model.

Operators need a safe terminal-console path from a canonically linked guest,
through its selected PVE and edge agent, without exposing the PVE endpoint,
provider credential, or ephemeral console ticket to the browser.

## What Changes

- Add a native `proxmox_guest_terminal` adapter for LXC consoles and QEMU
  guests with an available serial terminal, using Proxmox-issued short-lived
  console tickets through the selected edge agent.
- Admit a guest-console session only when its cluster, PVE node, VMID, and
  guest type are uniquely resolved from trusted virtualization inventory and
  the selected agent has a partition-bound, credential-scoped console
  assignment.
- Reuse the existing browser terminal, generic remote-access session, ticket,
  route-binding, timeout, and audit surfaces; the browser never contacts the
  PVE API or receives provider secrets/tickets.
- Keep the PVE API credential and all termproxy/websocket tickets in agent
  memory for one session only. A provider console authenticates to Proxmox; it
  does not create a guest-OS identity, and ServiceRadar SHALL NOT collect or
  persist guest login credentials for this path.
- Keep graphical QEMU VNC/noVNC/SPICE/RFB consoles, Windows desktop access,
  PVE power/configuration actions, and arbitrary provider-proxying out of
  scope. A guest without a supported terminal console remains unavailable with
  a precise non-secret reason.

## Impact

- Affected specs: `proxmox-console-access`, `edge-architecture`
- Affected code: Proxmox guest identity/read-model admission, remote-access
  session broker, scoped credential grants, agent Proxmox console adapter,
  browser terminal/device-details availability, audit events, integration
  fixtures, and operator documentation.
