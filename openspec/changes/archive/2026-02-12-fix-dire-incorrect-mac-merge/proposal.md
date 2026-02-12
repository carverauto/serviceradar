# Change: Fix DIRE incorrectly merging polled device with polling agent

## Why

DIRE incorrectly merged farm01 into tonka01 (issue #2780). There are two bugs that conspired:

### Bug 1: Polling agent ID passed during interface MAC registration

In `mapper_results_ingestor.ex:176-195` (introduced in commit `b3d162fb9`, Feb 10), when registering interface MACs discovered via SNMP, the code passes the **polling agent's ID** (`agent-dusk`) alongside the **polled device's MAC**. DIRE sees these two identifiers pointing to different devices and triggers an `identifier_conflict` merge.

**Sequence:** agent-dusk (at `192.168.2.22`) SNMP-polls tonka01 (`192.168.10.1`) → mapper discovers tonka01's MAC `0e:ea:14:32:d2:78` → `register_interface_mac` passes `{agent_id: "agent-dusk", mac: "0EEA1432D278"}` for tonka01 → DIRE resolves MAC → tonka01, agent_id → agent-dusk's device → **Conflict → Merge → farm01's data destroyed.**

Before Feb 10, `agent_id` was always `nil` in this path. Agent identity is registered through other paths (agent self-registration, sysmon reporting).

### Bug 2: No device creation for mapper-discovered hosts

The mapper discovers interfaces on farm01 (192.168.2.1) via agent-dusk's SNMP polling, but `resolve_device_ids()` (line 125-150) only looks up **existing** devices by IP. If no device exists for farm01, its interface records are silently dropped. Combined with the `remove-sweep-device-creation` change that stopped sweeps from creating devices, farm01 has **no creation path** — sweeps find it alive but can't create a device; mapper discovers its interfaces but can't create a device. Farm01 never got a proper `sr:` device record.

## What Changes

1. **Revert agent_id in interface MAC registration** — Set `agent_id: nil` in `register_interface_mac`. The `agent_id` field in interface records is the *polling agent*, not the device owner. Agent identity is registered through agent self-registration and device update paths. This reverts the mapper_results_ingestor.ex portion of commit `b3d162fb9` to the pre-Feb-10 behavior.

2. **Mapper creates devices for unresolved IPs** — When `resolve_device_ids` encounters an interface IP with no existing device, route it through DIRE to create a device with a proper `sr:` UUID. This ensures mapper-discovered devices (like farm01 polled via SNMP) get created in inventory, closing the gap left by `remove-sweep-device-creation`.

3. **Locally-administered MAC classification** — Classify MACs using IEEE bit 1 of the first octet. Register locally-administered MACs with `medium` confidence and exclude them from merge decisions. Prevents future false merges from virtual/overlay MACs.

4. ~~**Hostname conflict guard**~~ — REVERTED. Hostname is not an identity signal — devices commonly share hostnames (same model name) and the same device gets different hostnames from different sources (SNMP sysName vs UniFi display name). MAC confidence classification (#3) provides the correct merge protection.

5. **Device unmerge capability** — Admin action to reverse incorrect merges using the `merge_audit` trail.

## Impact

- Affected specs: `device-identity-reconciliation`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/network_discovery/mapper_results_ingestor.ex` — primary fix (agent_id revert + device creation)
  - `elixir/serviceradar_core/lib/serviceradar/inventory/identity_reconciler.ex` — MAC classification, hostname guard, unmerge
  - `elixir/serviceradar_core/lib/serviceradar/inventory/device_identifier.ex` — confidence field usage
- **BREAKING**: None. Existing correct merges are unaffected.
