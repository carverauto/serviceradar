# Routing Notes: MetalLB Speaker vs Calico BGP (demo.serviceradar.cloud)

## What happened

- `demo.serviceradar.cloud` DNS was recreated successfully by `external-dns` and resolves publicly to `23.138.124.2`.
- Reachability still failed after disabling MetalLB `speaker`.

## Why it failed

Your FRR/router state shows:

- `show bgp ipv4 unicast 23.138.124.2/32` -> **not in table**
- Route exists for aggregate `23.138.124.0/27` as **connected** (VLAN 104 / `br104`)

This means LB traffic is treated as local L2 for that subnet. Without MetalLB `speaker`, nothing responds to ARP/NDP for service IPs like `23.138.124.2`.

## Key distinction

Do not confuse:

- **VLAN tagging/trunking** (Proxmox/port config, VLAN 100/101/etc.)
- **Connected L3 subnet on router** (UniFi/FRR SVI/gateway)

You can keep VLAN tagging exactly as-is and still change LB routing behavior.

## Current options

1. Keep current LB pool in `23.138.124.0/27` and keep MetalLB `speaker` enabled.
2. Keep `speaker` disabled and move LB pool to a subnet that is **not connected L3** on the router.

## "Move LB pool" option (speakerless target)

Goal: LB CIDR must be routed by BGP, not connected on a VLAN interface.

### Steps

1. Choose a new LB CIDR from your owned space that is not configured as connected SVI/gateway on UniFi/FRR.
2. Keep Proxmox VLAN trunks and tagging unchanged.
3. Update MetalLB `IPAddressPool` to allocate from the new CIDR.
4. Update Calico `BGPConfiguration.spec.serviceLoadBalancerIPs` to include the new CIDR.
5. Reassign/recreate `LoadBalancer` services so they get new IPs.
6. `external-dns` updates DNS records to the new IPs.
7. Remove old pool usage after cutover.

## Important caution

- Do **not** remove VLAN 100 trunking from Proxmox interfaces.
- Only avoid/remove connected L3 interface behavior for the LB-only subnet.
- If you remove a UniFi network object that currently provides real host gateway/DHCP, you can break unrelated traffic.

## Recommended sequence

1. Re-enable speaker immediately for stability (if external reachability is currently broken).
2. Plan a maintenance window for LB CIDR migration.
3. Migrate to non-connected LB CIDR + Calico BGP advertisement.
4. Disable speaker again after end-to-end validation.
