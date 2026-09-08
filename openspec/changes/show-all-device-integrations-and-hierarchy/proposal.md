# Device Details: All Integrations + Guest/Hypervisor Hierarchy

## Why

DIRE merges a physical device discovered by multiple integrations (agent +
proxmox + AWX), but Device Details only renders one integration's metadata cards
(the "canonical source: Fallback" picker) instead of every source the device was
discovered through. Related gaps observed: (1) a PVE node's Device Details
sometimes shows a Guests tab and sometimes not (it flickers/disappears — a
symptom of node churn/fragmentation); (2) a guest whose parent hypervisor is
known does not link to that parent HV; (3) sysmon metrics for a long-running host
show only a short recent window (likely DIRE re-keying orphaning metrics keyed by
the pre-merge device/agent UID).

## What Changes

- Device Details lists all discovery integrations/sources for a merged device,
  not just the canonical/fallback one.
- A PVE node reliably shows its Guests tab; a guest shows a link to its
  parent/hypervisor device.
- Verify + fix sysmon metric continuity across a device merge (query by any of
  the merged identities, or re-key metrics on merge).

## Impact

- Affected specs: `device-details`.
- Affected code: web-ng device detail LiveView + device read model; sysmon
  metric read path (`cpu_metrics*`, keying vs merged UID). Depends on the proxmox
  identity/DIRE fix so nodes/guests stop fragmenting.
